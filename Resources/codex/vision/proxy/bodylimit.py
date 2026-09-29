"""请求体减肥：上游网关在 ~48–51MB 会随机 413 Payload Too Large（2026-09-30 实测）。

为什么需要它：Codex 每轮都把**整段历史**原样重发。做过图像迭代的会话里，历史会累积成
几十 MB 的 base64（截图 + view_image 结果 + 命令输出），于是"历史越长 → 请求越大 →
越容易撞上限"，最后这个线程**自己永远恢复不了**（重试也是同一个 413）。

实测边界（本地代理日志，同一体积 596 次 200 / 8 次 413）：
  * 成功最大 50,710,284 字节（48.4 MiB）
  * 413 最小 50,708,096 字节（48.4 MiB）
→ 上限就在 48.4 MiB 附近，边缘节点略有差异，所以阈值取 **45 MiB**（留 ~7% 余量）。

丢弃顺序（从旧到新，尽量保住"最近看到的画面"）：
  1. 历史里的图片：先丢"最近 2 条消息/工具调用之外"的（最老的先丢），
     还不够再丢那 2 条里的图（仍是最老的先丢，**永远留住最新 1 张**）；
  2. 还不够就丢大块工具输出（function_call_output / custom_tool_call_output > 32KB，可全丢）；
  3. 再不够就截断超大文本片段（> 8KB 的 text，可全截断）。
图片有两种形态，都要认（2026-09-30 在真实会话里核对过）：
  * 用户贴的截图：message.content 里的 input_image（21MB）
  * view_image 的结果：function_call_output.output **列表**里的 input_image（26MB）—— 只认前者会漏掉一半。
超限才会动手；动过就记一行日志（省了多少、丢了几张），**不改磁盘上的会话**（只改发往上游的这一份）。
"""

from __future__ import annotations

import json
import os

from .config import _log

DEFAULT_MAX_MB = 45
IMAGE_PLACEHOLDER = "[较早的截图已省略：请求体过大，已自动丢弃以适配上游上限]"
OUTPUT_PLACEHOLDER = "[较早的工具输出已省略：请求体过大，已自动丢弃以适配上游上限]"
TEXT_PLACEHOLDER = "\n…（较早的大段文本已截断：请求体过大）"

_IMAGE_TYPES = ("input_image", "image_url", "output_image")


def max_body_bytes() -> int:
    """上限（字节）。可用 VISION_MAX_BODY_MB 覆盖，默认 45 MiB。"""
    try:
        mb = int(os.environ.get("VISION_MAX_BODY_MB", "") or DEFAULT_MAX_MB)
    except ValueError:
        mb = DEFAULT_MAX_MB
    return max(1, mb) * 1024 * 1024


def _keep_recent(name: str, default: int) -> int:
    try:
        return max(0, int(os.environ.get(name, "") or default))
    except ValueError:
        return default


def _image_payload_size(part) -> int:
    """图片块里那段 base64/url 的字节数（估大小用，不解析图片）。"""
    if not isinstance(part, dict):
        return 0
    url = part.get("image_url") or part.get("url")
    if isinstance(url, dict):
        url = url.get("url")
    return len(url) if isinstance(url, str) else 0


def _part_size(part) -> int:
    """这一块占的字节数：图片算 base64/url 长度，文本算文本长度。"""
    if not isinstance(part, dict):
        return 0
    if part.get("type") in _IMAGE_TYPES:
        return _image_payload_size(part)
    text = part.get("text")
    return len(text) if isinstance(text, str) else 0


def _collect_image_parts(parsed):
    """按出现顺序收集 (容器列表, 下标, 块) 图片块 —— 消息里的和工具输出里的都算。"""
    out = []
    for item in parsed.get("input") or []:
        if not isinstance(item, dict):
            continue
        for key in ("content", "output"):
            container = item.get(key)
            if not isinstance(container, list):
                continue
            for idx, part in enumerate(container):
                if isinstance(part, dict) and part.get("type") in _IMAGE_TYPES:
                    out.append((container, idx, part))
    return out


def _recent_image_ids(parsed, keep_items: int):
    """最近 keep_items 条消息/工具调用里那些图片块的身份（id），单独保护到最后再丢。"""
    protected = set()
    if keep_items <= 0:
        return protected
    items = [it for it in (parsed.get("input") or []) if isinstance(it, dict)]
    for item in items[-keep_items:]:
        for key in ("content", "output"):
            container = item.get(key)
            if not isinstance(container, list):
                continue
            for part in container:
                if isinstance(part, dict) and part.get("type") in _IMAGE_TYPES:
                    protected.add(id(part))
    return protected


def _output_size(item) -> int:
    """工具输出当前占的字节数（字符串直算，列表按 JSON 估算）。"""
    output = item.get("output")
    if isinstance(output, str):
        return len(output)
    if output is None:
        return 0
    try:
        return len(json.dumps(output, ensure_ascii=False))
    except (TypeError, ValueError):
        return 0


def _collect_big_outputs(parsed, min_bytes=32 * 1024):
    """大块工具输出（保留最新若干条）。"""
    out = []
    for item in parsed.get("input") or []:
        if not isinstance(item, dict):
            continue
        if item.get("type") not in ("function_call_output", "custom_tool_call_output"):
            continue
        size = _output_size(item)
        if size >= min_bytes:
            out.append((item, size))
    return out


def _collect_big_text_parts(parsed, min_bytes=8 * 1024):
    """消息里的大段文本（保留最新若干条）。"""
    out = []
    for item in parsed.get("input") or []:
        if not isinstance(item, dict):
            continue
        content = item.get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if not isinstance(part, dict) or part.get("type") not in ("input_text", "output_text", "text"):
                continue
            text = part.get("text")
            if isinstance(text, str) and len(text) >= min_bytes:
                out.append((part, len(text)))
    return out


def _droppable(items, keep: int):
    """可以丢的那些（从旧到新）。注意 keep=0 时不能写 `items[:-0]` —— 那是空列表。"""
    if keep <= 0:
        return items
    return items[: len(items) - keep] if len(items) > keep else []


def shed_oversized_history(parsed, body_bytes: int, model=None):
    """体积超限时按"从旧到新"丢弃内容；返回新 body（bytes）或 None（没动）。

    只改内存里这份 payload，不碰磁盘会话 —— 下一轮如果又超限就再丢，直到看起来不超为止。
    """
    limit = max_body_bytes()
    if body_bytes <= limit or not isinstance(parsed, dict):
        return None

    saved = 0
    dropped_images = 0
    dropped_outputs = 0
    truncated_texts = 0

    def need() -> int:
        return body_bytes - saved - limit

    def replace_with_text(container, idx, text) -> None:
        nonlocal saved
        size = _part_size(container[idx])
        container[idx] = {"type": "input_text", "text": text}
        saved += max(0, size - len(text))

    # ① 图片：从最老开始丢；最近 keep_items 条消息/调用里的图留到最后（视觉迭代时当前截图最值钱）
    keep_items = max(1, _keep_recent("VISION_MIN_KEEP_ITEMS", 2))
    images = _collect_image_parts(parsed)
    protected = _recent_image_ids(parsed, keep_items)
    for container, idx, part in images:
        if need() <= 0:
            break
        if id(part) in protected:
            continue
        replace_with_text(container, idx, IMAGE_PLACEHOLDER)
        dropped_images += 1

    # ①b 还不够：继续丢被保护的那些（仍是从旧到新，永远留住最新 1 张）
    if need() > 0:
        for container, idx, part in images[: max(0, len(images) - 1)]:
            if need() <= 0:
                break
            if container[idx] is not part:
                continue  # 已经在 ① 里被替换过
            replace_with_text(container, idx, IMAGE_PLACEHOLDER)
            dropped_images += 1

    # ② 大块工具输出：从最老开始丢（可以全丢 —— 工具输出可重跑，用户的文字更值钱）
    if need() > 0:
        keep_outputs = max(0, _keep_recent("VISION_MIN_KEEP_OUTPUTS", 0))
        outputs = _collect_big_outputs(parsed)
        for item, size in _droppable(outputs, keep_outputs):
            if need() <= 0:
                break
            # 原来是列表就换成列表（网关只认数组时不至于翻车），原来是字符串就还是字符串。
            if isinstance(item.get("output"), list):
                item["output"] = [{"type": "input_text", "text": OUTPUT_PLACEHOLDER}]
            else:
                item["output"] = OUTPUT_PLACEHOLDER
            saved += max(0, size - len(OUTPUT_PLACEHOLDER))
            dropped_outputs += 1

    # ③ 超大文本：从最老开始截断（同样允许全截断，只留一段开头）
    if need() > 0:
        keep_texts = max(0, _keep_recent("VISION_MIN_KEEP_TEXTS", 0))
        texts = _collect_big_text_parts(parsed)
        for part, size in _droppable(texts, keep_texts):
            if need() <= 0:
                break
            head = part["text"][:500]
            part["text"] = head + TEXT_PLACEHOLDER
            saved += size - len(part["text"])
            truncated_texts += 1

    if not (dropped_images or dropped_outputs or truncated_texts):
        _log(f"[vision-proxy] body {body_bytes/1048576:.1f}MB 超上限 {limit/1048576:.0f}MB，"
             f"但没有可丢的图片/工具输出/大文本（model={model}）")
        return None

    new_body = bytearray(json.dumps(parsed).encode())
    still_over = len(new_body) > limit
    _log(f"[vision-proxy] 请求体减肥：{body_bytes/1048576:.1f}MB → {len(new_body)/1048576:.1f}MB "
         f"(上限 {limit/1048576:.0f}MB) · 丢图 {dropped_images} 张 · 丢工具输出 {dropped_outputs} 条 · "
         f"截断文本 {truncated_texts} 段 · 省 {saved/1048576:.1f}MB (model={model})"
         + ("· 仍超上限（已无可丢内容，这次可能还是 413）" if still_over else ""))
    return new_body
