#!/usr/bin/env python3
"""Auto-discover Go models from opencode.ai and sync models.json.

Fetches GET https://opencode.ai/zen/go/v1/models (no auth, 10s timeout),
handles 3 response shapes, lowercases/dedups, then clones a template
entry per new id into ~/.codex-deepseek/models.json with visibility=hide
(newModelPolicy=off). Safe to run repeatedly (TTL 24h, atomic write, backup).

Usage:
  python3 model_discovery.py --sync            # fetch + merge
  python3 model_discovery.py --sync --force    # ignore TTL
  python3 model_discovery.py --dry-run         # print what would be added
  python3 model_discovery.py --list            # print remote ids
  python3 model_discovery.py --sync-derived    # only rebuild 代理档位表 + 桌面白名单

每次 --sync 结束还会同步另两层"档位副本"（2026-09-10 起）：
  1) 目录层  models.json（模型自己声明几档）      <- 本文件主流程
  2) 代理层  reasoning_registry.json             <- 由目录生成，vision_proxy 读它做 clamp
  3) 桌面层  config.toml [desktop] enabled-reasoning-efforts
                                                <- 由目录生成，决定滑杆能显示几档
手工实测的档位请写 reasoning_overrides.json（覆盖层），registry 已是生成物，别手改。
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

GO_MODELS_URL = "https://opencode.ai/zen/go/v1/models"
GO_DOCS_URLS = ["https://opencode.ai/docs/zh-cn/go/", "https://opencode.ai/docs/go/"]
ZEN_MODELS_URL = "https://opencode.ai/zen/v1/models"
TTL_SECONDS = 24 * 3600
TIMEOUT = 10
QUOTA_TTL = 12 * 3600

CODEX_HOME = Path.home() / ".codex-deepseek"
MODELS_JSON = CODEX_HOME / "models.json"
CACHE_DIR = Path.home() / ".local/share/agent-vision-toolkit"
CACHE_FILE = CACHE_DIR / "go_models_cache.json"

# OpenCode Zen Free：上游 /zen/v1/models 动态识别（2026-09-05 改：原来硬编码 7 个，
# 新增 free（如 deepseek-v4-flash-free、muse-spark-1.3-contributor-free）永远进不来）。
# 规则：-free 后缀即 free 模型；big-pickle 是无后缀的历史特例（活着才收）。
ZEN_FREE_EXTRA_IDS = {"big-pickle"}
ZEN_FREE_EXCLUDE = set()
ZEN_FREE_LEGACY = [
    "big-pickle",
    "hy3-free",
    "ling-3.0-flash-fin-free",
    "mimo-v2.5-free",
    "muse-spark-1.2-contributor-free",
    "nemotron-3-ultra-free",
    "nemotron-3.5-lightning-free",
]
ZEN_FREE_IDS = ZEN_FREE_LEGACY  # 兼容旧引用；抓取失败时的回退名单
ZEN_CACHE_FILE = CACHE_DIR / "zen_models_cache.json"
REASONING_REGISTRY = CACHE_DIR / "reasoning_registry.json"
# 剪枝挂起表：模型第一次从配额表消失时只记一笔，要连续缺席 PRUNE_GRACE_SECONDS
# 才真剪。上游改文档/页面截断/正则撞车都不会再当场删掉能用的模型。
PRUNE_PENDING_FILE = CACHE_DIR / "prune_pending.json"
PRUNE_GRACE_SECONDS = 12 * 3600  # 两轮（launchd 每 6 小时跑一次）
GENERIC_REASONING = ["high"]

# 手工锁定的显示名 base（不含 "(Go)"/"(Zen)" 后缀）：
#   - Muse 家族是 picker 单行补丁的对照样本，别让官方 name 改掉
#   - big-pickle / muse-*-free 的官方 name 会丢掉 Free/Contributor 标记，照抄反而更差
#   - hy4-preview 官方写成 "Hy4 preview"（小写），本地保留首字母大写
DISPLAY_NAME_OVERRIDES = {
    "big-pickle": "Big Pickle Free",
    "muse-spark-1.3-contributor": "Muse Spark-1.3-Contributor",
    "muse-spark-1.2-contributor": "Muse Spark 1.2 Contributor",
    "muse-spark-1.3-contributor-free": "Muse Spark 1.3 Contributor Free",
    "hy4-preview": "Hy4-Preview",
}

# 手工实测档位覆盖层（唯一权威手工来源；首次运行自动从 reasoning_registry.json 迁移）
REASONING_OVERRIDES = CACHE_DIR / "reasoning_overrides.json"
# Codex 桌面端「模型控制可用档位」的白名单键（config.toml [desktop]）与档位顺序
DESKTOP_WHITELIST_KEY = "enabled-reasoning-efforts"
EFFORT_ORDER = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"]
APP_DEFAULT_EFFORTS = ["low", "medium", "high", "xhigh", "ultra", "persistent"]

# opencodex 上游上下文/档位（无需安装 opencodex，自动拉取）
UPSTREAM_URL = "https://raw.githubusercontent.com/lidge-jun/opencodex/main/src/codex/data/upstream-models.json"
UPSTREAM_CACHE = CACHE_DIR / "upstream_context_cache.json"
UPSTREAM_TTL = 24 * 3600

# models.dev（OpenCode 官方同源元数据库，2026-09-05 接入）
# Go 模型在 provider 'opencode-go'，Zen 免费在 'opencode'；OpenCode 客户端就是读它
MODELSDEV_URL = "https://models.dev/api.json"
MODELSDEV_CACHE = CACHE_DIR / "modelsdev_cache.json"
MODELSDEV_TTL = 24 * 3600

# 手工实测过的 context 覆盖（优先于 models.dev；如 hy3 实测 262144，models.dev 写 256000）
CONTEXT_OVERRIDES = {
    "hy3": 262144,
}

# Codex models.json schema 的 input_modalities 只认这三个（2026-09-05 副本卡 logo 实锤：
# models.dev 的 video/pdf 裸抄进 19 个模型 -> serde unknown variant -> config/read 全拒 -> 永远卡 splash）
ALLOWED_INPUT_MODALITIES = ("text", "image", "audio")

def _sanitize_modalities(mod):
    """models.dev modalities -> Codex 白名单交集；无合法值返回 None（保留模板现值）"""
    if not isinstance(mod, dict):
        return None
    kept = [v for v in (mod.get("input") or []) if v in ALLOWED_INPUT_MODALITIES]
    return kept or None

# Fallback 31 ids (2026-08-28 live snapshot)
FALLBACK_IDS = [
    "minimax-m3","minimax-m2.7","minimax-m2.5","kimi-k3","kimi-k2.7-code","kimi-k2.6",
    "longcat-2.0","kimi-k2.5","glm-5.2","glm-5.3-flash","glm-5.3","glm-5.1","glm-5",
    "deepseek-v4-pro","deepseek-v4-flash","deepseek-v4-flash-vision-exp",
    "qwen3.7-max","qwen3.8-max","qwen3.7-plus","qwen3.6-plus","qwen3.5-plus",
    "mimo-v2-pro","mimo-v2-omni","mimo-v2.5-pro","mimo-v2.5","hy3","hy3-preview",
    "gpt-5.6-luna","grok-4.5","grok-4.6","muse-spark-1.2-contributor",
    "union-alpha",
]

GO_ALIASES = {"ox-alpha": "ox-alpha-free"}  # keep for compat, but not needed for new ids

# Display name -> id map for quota table (normalized)
DISPLAY_TO_ID = {
    "kimi k3": "kimi-k3",
    "qwen3.8 max": "qwen3.8-max",
    "grok 4.6": "grok-4.6",
    "glm-5.3-flash": "glm-5.3-flash",
    "glm-5.3": "glm-5.3",
    "glm-5.2": "glm-5.2",
    "glm-5.1": "glm-5.1",
    "kimi k2.7 code": "kimi-k2.7-code",
    "kimi k2.6": "kimi-k2.6",
    "longcat-2.0": "longcat-2.0",
    "mimo-v2.5": "mimo-v2.5",
    "mimo-v2.5-pro": "mimo-v2.5-pro",
    "minimax m3": "minimax-m3",
    "minimax m2.7": "minimax-m2.7",
    "muse spark 1.2 contributor": "muse-spark-1.2-contributor",
    "qwen3.7 max": "qwen3.7-max",
    "qwen3.7 plus": "qwen3.7-plus",
    "qwen3.6 plus": "qwen3.6-plus",
    "deepseek v4 pro": "deepseek-v4-pro",
    "deepseek v4 flash vision exp": "deepseek-v4-flash-vision-exp",
    "deepseek v4 flash": "deepseek-v4-flash",
    # 2026-09-17：文档写 "Union Alpha Free"，网关真实 id 是 union-alpha
    # （归一猜测会得到 union-alpha-free → 401 Model not supported，models.dev 里也没有这条可校正）
    "union alpha free": "union-alpha",
    # 2026-09-10：Go 表格行名 "DeepSeek V4.1 Flash"，网关真实 id 是 deepseek-flash
    # （models.dev 同源；猜成 deepseek-v4.1-flash 会 401 Model not supported）
    "deepseek v4.1 flash": "deepseek-flash",
    "hy3": "hy3",
    "gpt 5.6 luna": "gpt-5.6-luna",
    "deepseek v4 flash vision exp": "deepseek-v4-flash-vision-exp",
    "qwen3.8 max": "qwen3.8-max",
}

def _norm_display(s):
    return re.sub(r"\s+", " ", s.strip().lower().replace("-", " ").replace("–", " ")).strip()

def _modelsdev_id_index():
    """models.dev 的「归一显示名 / 官方 id」-> 官方 id。用于把文档表格行名归一到网关真 id。"""
    idx = {}
    try:
        for mid, v in (fetch_modelsdev() or {}).items():
            idx.setdefault(_norm_display(str(mid)), mid)
            name = v[3] if len(v) > 3 else mid
            if name:
                idx.setdefault(_norm_display(str(name)), mid)
    except Exception:
        return {}
    return idx

def _align_remote_id(norm_display, guess):
    """把「猜出来的 id」跟 models.dev 对齐。猜错时（如 deepseek v4.1 flash）改回官方 id。"""
    idx = _modelsdev_id_index()
    if not idx:
        return guess
    known = set(idx.values())
    if guess in known:
        return guess
    hit = idx.get(norm_display) or idx.get(re.sub(r"\(.*\)", "", norm_display).strip())
    if hit:
        if hit != guess:
            _log(f"id 归一 {norm_display!r}: {guess} -> {hit} (models.dev)")
        return hit
    return guess

# 2026-09-17：Union Alpha Free 三格写「无限制」，白名单里只有「无限」-> 整行被当无效行丢掉，
# 连带 union-alpha-go 进不了 models.json。这里补上「无限制/不限/不限量」等写法。
FREE_TOKENS = {"-", "—", "", "限免", "免费", "无限", "无限制", "不限", "不限量",
               "∞", "不计配额", "限时免费", "限时免费不计配额", "free", "unlimited"}

def _is_free_val(v):
    t = v.strip().lower()
    return t in FREE_TOKENS or t == "无限" or "限免" in t or "免费" in t

def _log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

QUOTA_CACHE_FILE = CACHE_DIR / "go_quota_cache.json"
# 最近一次成功抓到的配额页（剥标签、只留字母数字的归一化文本）。
# 用途：剪枝前的安全闸——文档里还写着这个模型，就说明是解析漏行而不是上游下架。
LAST_QUOTA_PAGE = ""

_TAG_RE = re.compile(r"<[^>]*>")

def _norm_key(s):
    """归一化到只剩字母数字，用于「文档里还提不提到这个 id」的判断。"""
    return re.sub(r"[^a-z0-9]", "", str(s).lower())

def _strip_tags(s):
    return _TAG_RE.sub(" ", s)

def _cell_value(cell):
    """取单元格的「当前生效值」。

    配额表会给促销行加装饰：<del>旧值</del><br><strong>新值</strong>。
    有 <strong> 就取最后一个（当前值），否则整格剥标签。
    """
    strong = re.findall(r"<strong>(.*?)</strong>", cell, re.S | re.I)
    raw = strong[-1] if strong else cell
    return re.sub(r"\s+", " ", _strip_tags(raw)).strip()

def _cell_name(cell):
    """取行名：先丢掉 <br> 后面的促销备注（如 `4x · 9 月 20 日结束`）再剥标签。"""
    head = re.split(r"<br\s*/?>", cell, maxsplit=1, flags=re.I)[0]
    strong = re.findall(r"<strong>(.*?)</strong>", head, re.S | re.I)
    raw = strong[-1] if strong else head
    return re.sub(r"\s+", " ", _strip_tags(raw)).strip()

def parse_quota_rows(html):
    """解析配额表 -> [(名称, 5小时, 每周, 每月)]，容忍单元格里的任意嵌套标签。

    2026-09-14 事故：官方给 DeepSeek V4.1 Flash 那行加了
    `<br><small>4x · 9 月 20 日结束</small>` 和 `<del>6500</del><br><strong>26000</strong>`
    双值，旧正则 `<td>([^<]+)</td>` 匹配不到带标签的单元格 -> 整行消失 ->
    配额 id 27->26 -> 同步把 deepseek-v4.1-flash-go 当野模型剪掉，Codex 里再也选不到。
    所以这里一律「剥标签取文本」，不再假设单元格是纯文本。
    """
    rows = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", html, re.S | re.I):
        cells = re.findall(r"<td[^>]*>(.*?)</td>", row, re.S | re.I)
        if len(cells) != 4:
            continue
        rows.append((_cell_name(cells[0]), _cell_value(cells[1]),
                     _cell_value(cells[2]), _cell_value(cells[3])))
    return rows

def _quota_page_key():
    """本次（或缓存里上次成功抓取）配额页的归一化文本。"""
    if LAST_QUOTA_PAGE:
        return LAST_QUOTA_PAGE
    try:
        return json.loads(QUOTA_CACHE_FILE.read_text()).get("page_norm") or ""
    except Exception:
        return ""

def _load_prune_pending():
    """{bare_id: 首次发现缺席的时间戳}；读不到就当空。"""
    d = _read_json(PRUNE_PENDING_FILE, {})
    return d if isinstance(d, dict) else {}

def _save_prune_pending(d):
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = PRUNE_PENDING_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(d, ensure_ascii=False, indent=1) + "\n")
        tmp.replace(PRUNE_PENDING_FILE)
    except Exception as e:
        _log(f"prune_pending 写失败: {e!r}")

def fetch_quota_ids(timeout=TIMEOUT):
    """Fetch Go quota table as ids; auto-detect free rows (三列全 -/限免 => free) like Widget."""
    global LAST_QUOTA_PAGE
    for url in GO_DOCS_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0","Accept":"*/*"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                html = r.read().decode(errors="replace")
            rows = parse_quota_rows(html)
            page_key = _norm_key(_strip_tags(html))
            # filter header row and price table
            filtered = []
            for x in rows:
                if x[0].strip().lower() in ("model","模型"):
                    continue
                if "$" in x[1] or "$" in x[2] or "$" in x[3]:
                    continue
                # quota row: at least h5 and weekly are numeric or free token
                h5, wk, mo = x[1].strip(), x[2].strip(), x[3].strip()
                h5_is = h5.replace(",","").replace("，","").isdigit() or _is_free_val(h5)
                wk_is = wk.replace(",","").replace("，","").isdigit() or _is_free_val(wk)
                mo_is = mo.replace(",","").replace("，","").isdigit() or _is_free_val(mo)
                # need at least h5 or wk is quota/free, and mo is quota/free (Widget requires h5+weekly)
                if not (h5_is and wk_is):
                    # allow free row where all three are free
                    if _is_free_val(h5) and _is_free_val(wk) and _is_free_val(mo):
                        pass
                    else:
                        continue
                filtered.append(x)
            rows = filtered
            ids = []
            for disp, h5, wk, mo in rows:
                norm = _norm_display(disp)
                rid = DISPLAY_TO_ID.get(norm)
                if not rid:
                    # handle "Ox Alpha Free" etc with parentheses
                    norm2 = re.sub(r"\(.*\)", "", norm).strip()
                    rid = DISPLAY_TO_ID.get(norm2)
                if not rid:
                    rid = re.sub(r"[^a-z0-9.\-]", "-", norm).strip("-")
                    rid = re.sub(r"-+", "-", rid).strip("-")
                    rid = rid.replace("gpt-5-6-luna","gpt-5.6-luna")
                # 归一：拿 models.dev 的官方 id 校正猜出来的 id（2026-09-10 加）
                rid = _align_remote_id(norm, rid)
                if rid and rid not in ids:
                    ids.append(rid)
            if len(ids) >= 10:
                LAST_QUOTA_PAGE = page_key
                # 与上次成功抓取对比：少了谁、少的那个是不是还在页面上（=解析漏行）
                prev_ids = []
                try:
                    prev_ids = json.loads((CACHE_DIR / "go_quota_cache.json").read_text()).get("ids") or []
                except Exception:
                    prev_ids = []
                gone = [i for i in prev_ids if i not in ids]
                if gone:
                    still = [i for i in gone if _norm_key(i) and _norm_key(i) in page_key]
                    _log(f"quota ids {len(prev_ids)} -> {len(ids)}，减少 {gone}"
                         + (f"；其中 {still} 在页面上仍出现 -> 判定解析漏行，剪枝已拦" if still else ""))
                try:
                    CACHE_DIR.mkdir(parents=True, exist_ok=True)
                    qc = {"ids": ids, "fetchedAt": int(time.time()), "page_norm": page_key}
                    (CACHE_DIR / "go_quota_cache.json").write_text(json.dumps(qc, ensure_ascii=False))
                except Exception:
                    pass
                _log(f"quota table {url} -> {len(ids)} ids")
                return ids
        except Exception as e:
            _log(f"quota fetch {url} failed: {e!r}")
            continue
    try:
        qc = json.loads((CACHE_DIR / "go_quota_cache.json").read_text())
        if time.time() - qc.get("fetchedAt",0) < QUOTA_TTL:
            ids = qc["ids"]
            LAST_QUOTA_PAGE = qc.get("page_norm") or ""
            _log(f"quota cache -> {len(ids)} ids")
            return ids
    except Exception:
        pass
    return None

def fetch_remote_ids(timeout=TIMEOUT):
    req = urllib.request.Request(GO_MODELS_URL, headers={"Accept": "*/*", "User-Agent": "model-discovery/1.0"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            data = json.loads(raw.decode())
    except Exception as e:
        _log(f"fetch failed: {e!r}")
        return None
    # 3 shapes: {"data":[{"id":...}]}, ["id"], {"data":["id"]}
    ids = []
    if isinstance(data, list):
        for v in data:
            if isinstance(v, str):
                ids.append(v)
            elif isinstance(v, dict) and isinstance(v.get("id"), str):
                ids.append(v["id"])
    elif isinstance(data, dict):
        d = data.get("data")
        if isinstance(d, list):
            for v in d:
                if isinstance(v, str):
                    ids.append(v)
                elif isinstance(v, dict) and isinstance(v.get("id"), str):
                    ids.append(v["id"])
    # normalize
    seen = set()
    out = []
    for i in ids:
        n = i.strip().lower()
        if not n or n in seen:
            continue
        seen.add(n)
        out.append(n)
    return out if out else None

def load_cache():
    if not CACHE_FILE.exists():
        return None
    try:
        j = json.loads(CACHE_FILE.read_text())
        return j
    except Exception:
        return None

def save_cache(ids):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    j = {"ids": ids, "fetchedAt": int(time.time()), "fetchedAtStr": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    tmp = CACHE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(j, ensure_ascii=False, indent=2))
    tmp.replace(CACHE_FILE)

def is_cache_fresh(cache):
    if not cache:
        return False
    age = time.time() - cache.get("fetchedAt", 0)
    return age < TTL_SECONDS

def load_models_json():
    if not MODELS_JSON.exists():
        return {"models": []}
    return json.loads(MODELS_JSON.read_text())

def _reasoning_registry_path():
    return CACHE_DIR / "reasoning_registry.json"

def _reasoning_overrides_path():
    return CACHE_DIR / "reasoning_overrides.json"

def _read_json(path, default):
    try:
        if path.exists():
            return json.loads(path.read_text())
    except Exception:
        pass
    return default

def load_reasoning_overrides():
    """手工实测档位覆盖层（唯一权威手工来源）。

    首次运行从旧的 reasoning_registry.json 迁移一次；此后 registry 是生成物
    （目录 + 覆盖层派生），要手改请改 reasoning_overrides.json。
    """
    path = _reasoning_overrides_path()
    if path.exists():
        return _read_json(path, {})
    legacy = _read_json(_reasoning_registry_path(), {})
    if legacy:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(legacy, ensure_ascii=False, indent=1) + "\n")
            tmp.replace(path)
            _log(f"迁移 {len(legacy)} 条手工档位 -> {path.name}（registry 从此自动生成）")
        except Exception as e:
            _log(f"override migration failed: {e!r}")
    return legacy

def fetch_upstream_details(timeout=TIMEOUT):
    """拉 opencodex 上游的 context / 档位，24h 缓存，失败回退。返回 {slug: (context, levels)}"""
    try:
        if UPSTREAM_CACHE.exists():
            try:
                j = json.loads(UPSTREAM_CACHE.read_text())
                if time.time() - j.get("fetchedAt", 0) < UPSTREAM_TTL and isinstance(j.get("map"), dict):
                    return {k: (v[0], v[1]) for k, v in j["map"].items()}
            except Exception:
                pass
        req = urllib.request.Request(UPSTREAM_URL, headers={"User-Agent": "model-discovery/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode())
        m = {}
        for mod in data.get("models", []):
            slug = (mod.get("slug") or "").strip().lower()
            if not slug:
                continue
            ctx = mod.get("context_window") or mod.get("max_context_window") or 0
            levels = []
            for lv in mod.get("supported_reasoning_levels") or []:
                eff = lv.get("effort") if isinstance(lv, dict) else str(lv)
                if eff:
                    levels.append(eff)
            if ctx or levels:
                m[slug] = (int(ctx) if ctx else 0, levels)
            if not slug.endswith("-go") and slug + "-go" not in m and (ctx or levels):
                m[slug + "-go"] = (int(ctx) if ctx else 0, levels)
        if m:
            try:
                CACHE_DIR.mkdir(parents=True, exist_ok=True)
                UPSTREAM_CACHE.write_text(json.dumps({"fetchedAt": int(time.time()), "map": {k: [v[0], v[1]] for k, v in m.items()}}, ensure_ascii=False))
            except Exception:
                pass
            _log(f"upstream context {len(m)} entries")
            return m
    except Exception as e:
        _log(f"upstream fetch failed: {e!r}")
    try:
        j = json.loads(UPSTREAM_CACHE.read_text())
        mm = j.get("map") or {}
        return {k: (v[0], v[1]) for k, v in mm.items()}
    except Exception:
        return {}

def fetch_modelsdev(timeout=30):
    """拉 models.dev（OpenCode 官方同源），返回 {bare_id: (context, levels, modalities, name, provider)}。
    levels 已过滤 minimal（Codex 端下不了，见 skill §15）。"""
    try:
        if MODELSDEV_CACHE.exists():
            try:
                j = json.loads(MODELSDEV_CACHE.read_text())
                # 旧缓存只有 3 个字段（无 name/provider），缺字段时视为过期，重新拉
                if (time.time() - j.get("fetchedAt", 0) < MODELSDEV_TTL
                        and isinstance(j.get("map"), dict)
                        and all(len(v) >= 5 for v in j["map"].values())):
                    return {k: tuple(v) for k, v in j["map"].items()}
            except Exception:
                pass
        req = urllib.request.Request(MODELSDEV_URL, headers={"User-Agent": "model-discovery/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode())
        m = {}
        for prov in ("opencode-go", "opencode"):  # opencode-go 优先
            p = data.get(prov) or {}
            for mid, mod in (p.get("models") or {}).items():
                if mid in m:
                    continue
                ctx = ((mod.get("limit") or {}).get("context")) or 0
                levels = []
                for opt in mod.get("reasoning_options") or []:
                    if opt.get("type") == "effort":
                        levels = [v for v in (opt.get("values") or []) if v != "minimal"]
                        break
                if ctx or levels:
                    m[mid] = (int(ctx) if ctx else 0, levels, mod.get("modalities") or {},
                              mod.get("name") or mid, prov)
        if m:
            try:
                CACHE_DIR.mkdir(parents=True, exist_ok=True)
                MODELSDEV_CACHE.write_text(json.dumps(
                    {"fetchedAt": int(time.time()), "map": {k: list(v) for k, v in m.items()}},
                    ensure_ascii=False))
            except Exception:
                pass
        _log(f"models.dev {len(m)} entries")
        return m
    except Exception as e:
        _log(f"models.dev fetch failed: {e!r}")
        try:
            j = json.loads(MODELSDEV_CACHE.read_text())
            return {k: tuple(v) for k, v in (j.get("map") or {}).items()}
        except Exception:
            return {}

def fetch_zen_free_ids(timeout=TIMEOUT):
    """实时拉 Zen Free，动态识别（-free 后缀），失败回退缓存/硬编码名单"""
    try:
        req = urllib.request.Request(ZEN_MODELS_URL, headers={"Accept":"*/*","User-Agent":"model-discovery/1.0"})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=timeout) as r:
            data = json.loads(r.read().decode())
        # 3 shapes
        raw_ids = []
        if isinstance(data, list):
            for v in data:
                if isinstance(v, str): raw_ids.append(v)
                elif isinstance(v, dict) and isinstance(v.get("id"), str): raw_ids.append(v["id"])
        elif isinstance(data, dict):
            d = data.get("data")
            if isinstance(d, list):
                for v in d:
                    if isinstance(v, str): raw_ids.append(v)
                    elif isinstance(v, dict) and isinstance(v.get("id"), str): raw_ids.append(v["id"])
        raw_ids = [x.strip().lower() for x in raw_ids if x]
        # 动态识别：-free 后缀 + 历史特例，排除名单兜底（不再硬编码 7 个）
        ids = [i for i in raw_ids if (i.endswith("-free") or i in ZEN_FREE_EXTRA_IDS) and i not in ZEN_FREE_EXCLUDE]
        # 去重保序
        ids = list(dict.fromkeys(ids))
        if len(ids) >= 1:
            try:
                CACHE_DIR.mkdir(parents=True, exist_ok=True)
                qc={"ids":ids,"fetchedAt":int(time.time())}
                ZEN_CACHE_FILE.write_text(json.dumps(qc, ensure_ascii=False))
            except Exception:
                pass
            _log(f"zen free live {len(ids)} ids: {','.join(ids)}")
            return ids
    except Exception as e:
        _log(f"zen fetch failed: {e!r}")
    # fallback cache
    try:
        qc=json.loads(ZEN_CACHE_FILE.read_text())
        ids=qc.get("ids") or []
        _log(f"zen cache -> {len(ids)} ids")
        return ids if ids else ZEN_FREE_IDS
    except Exception:
        pass
    return ZEN_FREE_IDS

def find_template(models, remote_id):
    # pick best template by prefix
    slug_map = {m["slug"]: m for m in models}
    def get(slug):
        return slug_map.get(slug)
    if remote_id.startswith("deepseek-"):
        return get("deepseek-v4-flash-go") or get("deepseek-v4-pro-go") or models[0]
    if remote_id.startswith("gpt-"):
        return get("gpt-5.6-luna-go") or get("deepseek-v4-flash-go") or models[0]
    if remote_id.startswith("muse-"):
        return get("muse-spark-1.2-contributor-go") or models[0]
    if remote_id.startswith("mimo-"):
        return get("mimo-v2.5-go") or get("mimo-v2.5-pro-go") or models[0]
    if remote_id.startswith("glm-"):
        return get("glm-5-go") or get("glm-5.3-go") or models[0]
    if remote_id.startswith("hy3"):
        # hy3 native responses
        return get("glm-5-go") or models[0]
    # generic chat-adapted fallback: use mimo template (supports tool call, image, no search)
    return get("mimo-v2.5-go") or get("glm-5-go") or models[0]

def _display_base_from_official(official_name, remote_id):
    """models.dev 官方 name -> 基名；拿不到（或只是 id 本身）返回 None。

    2026-09-11 加：显示名以官方 name 为权威。此前完全由 id 拼（id.replace("-", " ").title()），
    于是 deepseek-v4.1-flash 变成 "Deepseek-V4.1-Flash"、minimax 变成 "Minimax"，
    跟 OpenCode 客户端/新机器上看到的 "DeepSeek V4.1 Flash" 对不上。
    """
    if not isinstance(official_name, str):
        return None
    base = official_name.strip()
    # 官方给 deepseek-v4-pro 挂过 "(New)" 水印，展示层不需要
    base = re.sub(r"\s*\((?:new|beta|preview)\)\s*$", "", base, flags=re.IGNORECASE).strip()
    # 只挡掉「官方名就是 id 本身」的情况；大小写/连字符差异（Minimax-M3 -> MiniMax-M3）要保留
    if not base or base == str(remote_id):
        return None
    return base

def _display_name_for(remote_id, suffix, official_name=None):
    # suffix = "Go" or "Zen"
    # 优先级：手工 override > models.dev 官方 name > 由 id 拼（老逻辑，兜底）
    # Zen: keep spaces e.g. "Muse Spark 1.2 Free (Zen)" to match screenshot
    # Go: keep hyphens for version e.g. "MiMo-V2.5 (Go)"
    if remote_id in DISPLAY_NAME_OVERRIDES:
        return f"{DISPLAY_NAME_OVERRIDES[remote_id]} ({suffix})"
    official = _display_base_from_official(official_name, remote_id)
    if official:
        if suffix != "Go":
            return f"{official} ({suffix})"
        # 官方名照抄词序/大小写，只把空格换成连字符对齐 Go 组习惯；Muse 保留空格
        base = official.replace(" ", "-")
        base = base.replace("Muse-Spark", "Muse Spark").replace("Gpt-", "GPT-").replace("Glm-", "GLM-")
        return f"{base} ({suffix})"
    if suffix == "Zen":
        if remote_id == "big-pickle":
            base = "Big Pickle Free"
        elif remote_id == "muse-spark-1.2-contributor-free":
            base = "Muse Spark 1.2 Free"
        elif remote_id.endswith("-free"):
            base_raw = remote_id[:-5]
            base = base_raw.replace("-", " ").title()
            base = base.replace("Gpt ", "GPT ").replace("Muse ", "Muse ").replace("Mimo ", "MiMo ").replace("Glm ", "GLM ").replace("Nemotron ", "Nemotron ").replace("Deepseek ", "DeepSeek ")
            base = base + " Free"
        else:
            base = remote_id.replace("-", " ").title()
            base = base.replace("Gpt ", "GPT ").replace("Muse ", "Muse ").replace("Mimo ", "MiMo ").replace("Glm ", "GLM ")
        return f"{base} ({suffix})"
    else:
        if remote_id == "big-pickle":
            base = "Big Pickle Free"
        elif remote_id.endswith("-free"):
            base_raw = remote_id[:-5]
            base = base_raw.replace("-", " ").title().replace(" ", "-")
            base = base.replace("Gpt-", "GPT-").replace("Muse-", "Muse ").replace("Mimo-", "MiMo-").replace("Glm-", "GLM-").replace("Nemotron-", "Nemotron ").replace("Deepseek-", "DeepSeek-")
            base = base + " Free"
        else:
            base = remote_id.replace("-", " ").title().replace(" ", "-")
            base = base.replace("Gpt-", "GPT-").replace("Muse-", "Muse ").replace("Mimo-", "MiMo-").replace("Glm-", "GLM-")
        return f"{base} ({suffix})"

def build_entry(template, remote_id, priority, upstream_map=None, modelsdev_map=None, is_zen=None):
    e = copy.deepcopy(template)
    if is_zen is None:
        # 兼容旧调用：启发式判断（sync 主流程现在显式传 is_zen）
        is_zen = remote_id in ZEN_FREE_IDS or remote_id.endswith("-free") and remote_id in ZEN_FREE_IDS or remote_id == "big-pickle"
    suffix = "Zen" if is_zen else "Go"
    slug_suffix = "-zen" if is_zen else "-go"
    slug = remote_id + slug_suffix
    upstream_map = upstream_map or {}
    modelsdev_map = modelsdev_map or {}
    lookup = remote_id
    if is_zen and remote_id.endswith("-free"):
        lookup = remote_id[:-5]
    if lookup == "big-pickle":
        lookup = "big-pickle"
    md = modelsdev_map.get(remote_id) or modelsdev_map.get(lookup)
    e["slug"] = slug
    # 官方 name 只在按真 id 命中时采信（避免拿非 free 条目的名字去命名 free 模型）
    e["display_name"] = _display_name_for(remote_id, suffix, (md[3] if (md and len(md) > 3 and remote_id in modelsdev_map) else None))
    e["description"] = f"OpenCode {'Zen Free' if is_zen else 'Go'} model ({remote_id}), routed via opencode.ai {'Zen' if is_zen else 'Zen/Go'} proxy. auto-discovered {time.strftime('%Y-%m-%d')}"
    e["priority"] = priority
    e["visibility"] = "list"
    if not is_zen and remote_id.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
        e["supports_search_tool"] = True
        if "web_search_tool_type" not in e:
            e["web_search_tool_type"] = "text"
    else:
        e["supports_search_tool"] = False
        e.pop("web_search_tool_type", None)
    # 上下文与档位：本地 registry 手工实测 > models.dev（OpenCode 官方同源）> opencodex 上游 > 模板现值
    # （md 已在函数开头解析，显示名与档位共用同一次查询）
    up_ctx, up_levels = 0, None
    for key in (remote_id, lookup, slug, remote_id + "-go", lookup + "-go"):
        if key in upstream_map:
            up_ctx, up_levels = upstream_map[key]
            break
    # context：手工覆盖 > models.dev > opencodex
    ctx_final = CONTEXT_OVERRIDES.get(lookup) or (md[0] if md else 0) or up_ctx
    if ctx_final and ctx_final > 0:
        e["context_window"] = ctx_final
        e["max_context_window"] = ctx_final
        e["effective_context_window_percent"] = e.get("effective_context_window_percent", 95)
    # modalities：models.dev 为准，但必须过 Codex 白名单（video/pdf 会炸整个 models.json）
    san = _sanitize_modalities(md[2]) if md else None
    if san:
        e["input_modalities"] = san
    reg = load_reasoning_overrides()
    levels = reg.get(remote_id) or reg.get(lookup)
    if levels is None:
        md_levels = md[1] if md else None
        levels = md_levels or up_levels
    if levels is None:
        levels = GENERIC_REASONING
    descs = {
        "low": "Fast responses with lighter reasoning",
        "medium": "Balanced reasoning for everyday tasks",
        "high": "Extra high reasoning depth for complex problems",
        "xhigh": "Extended reasoning depth for harder tasks",
        "max": "Maximum reasoning depth for the hardest problems",
        "none": "No reasoning",
        "ultra": "Maximum reasoning with automatic task delegation",
    }
    e["supported_reasoning_levels"] = [{"effort": lv, "description": descs.get(lv, lv)} for lv in levels]
    e["default_reasoning_level"] = levels[0] if levels else "high"
    e["supported_in_api"] = True
    return e

def sync(force=False, dry_run=False):
    # quota table is the source of truth (限免 + 三段配额), not /v1/models
    # 返回 None = 抓不到表，这时用上次成功的 24 缓存顶着，绝不回退到 31 野名单
    qids = fetch_quota_ids()
    if qids:
        ids = qids
        _log(f"quota source {len(ids)} ids")
        # also refresh /v1/models cache for bookkeeping but not used for sync
        try:
            rids = fetch_remote_ids()
            if rids:
                save_cache(rids)
        except Exception:
            pass
    else:
        # 抓不到配额表 -> 用上次成功的 quota 缓存顶着，有新模型要等下次抓成功才进来
        try:
            qc = json.loads(QUOTA_CACHE_FILE.read_text())
            ids = qc.get("ids") or []
            age = int(time.time() - qc.get("fetchedAt", 0))
            if ids and len(ids) >= 10:
                _log(f"quota fetch failed, use last quota cache {len(ids)} ids age {age}s (新模型等下次成功再进)")
            else:
                _log("quota fetch failed and quota cache invalid, skip sync (不回退到31野名单)")
                return 0
        except Exception as e:
            _log(f"quota fetch failed and no quota cache ({e!r}), skip sync (不回退到31)")
            return 0

    # also fetch Zen Free 7
    try:
        prev_zen = json.loads(ZEN_CACHE_FILE.read_text()).get("ids") or []
    except Exception:
        prev_zen = []
    zen_ids = fetch_zen_free_ids()
    gone_zen = [i for i in prev_zen if i not in set(zen_ids)]
    if gone_zen:
        _log(f"zen ids {len(prev_zen)} -> {len(zen_ids)}，减少 {gone_zen}（若上游只是抽风，下轮会自动回来）")
    zen_slugs = {i + "-zen" if i != "big-pickle" else "big-pickle-zen" for i in zen_ids}
    # treat Zen ids for template lookup (map to same)
    j = load_models_json()
    models = j.get("models", [])
    existing_slugs = {m["slug"] for m in models}
    max_prio = max((m.get("priority", 0) for m in models), default=0)

    upstream_map = fetch_upstream_details()
    modelsdev_map = fetch_modelsdev()
    # Only quota-driven sync: ids is quota source (25)
    to_add = []
    for rid in ids:
        slug = rid + "-go"
        if slug in existing_slugs:
            continue
        tmpl = find_template(models, rid)
        if not tmpl:
            _log(f"no template for {rid}, skip")
            continue
        entry = build_entry(tmpl, rid, max_prio + len(to_add) + 1, upstream_map=upstream_map, modelsdev_map=modelsdev_map, is_zen=False)
        to_add.append(entry)
    # add Zen Free
    for rid in zen_ids:
        slug = rid + "-zen" if rid != "big-pickle" else "big-pickle-zen"
        if slug in existing_slugs or slug in {e["slug"] for e in to_add}:
            continue
        tmpl = find_template(models, rid)
        if not tmpl:
            _log(f"no template for zen {rid}, skip")
            continue
        entry = build_entry(tmpl, rid, max_prio + len(to_add) + 1, upstream_map=upstream_map, modelsdev_map=modelsdev_map, is_zen=True)
        to_add.append(entry)

    # Prune wild Go models not in quota (乱七八糟的) ; keep Zen separately
    quota_bare = set(ids)
    zen_bare = set(zen_ids)
    # 剪枝安全闸（2026-09-14 事故后加）：配额页里还出现这个名字，就说明是我们没解析出来
    # （官方给行加了促销装饰/改了表格结构），不是上游下架 —— 这时候绝不能把模型剪掉。
    page_key = _quota_page_key()
    pending = _load_prune_pending()
    now = int(time.time())
    to_keep = []
    pruned = []
    held = []
    graced = []
    for m in models:
        slug = m.get("slug","")
        if slug.endswith("-zen"):
            bare = slug[:-4]
            if bare in zen_bare:
                to_keep.append(m)
            else:
                pruned.append(slug)
            continue
        if not slug.endswith("-go"):
            to_keep.append(m)
            continue
        bare = slug[:-3]
        if bare in quota_bare:
            pending.pop(bare, None)
            to_keep.append(m)
        elif page_key and _norm_key(bare) and _norm_key(bare) in page_key:
            held.append(slug)
            to_keep.append(m)
            pending.pop(bare, None)
        else:
            # 二次确认：第一次缺席只记账，连续缺席超过宽限期才真剪。
            # 这样上游改文档 / 抓取截断 / 正则撞车都不会当场删掉能用的模型。
            first = pending.get(bare)
            if first is None or now - int(first) < PRUNE_GRACE_SECONDS:
                if first is None:
                    pending[bare] = now
                graced.append(slug)
                to_keep.append(m)
            else:
                pruned.append(slug)
                pending.pop(bare, None)
    if held:
        _log(f"safety-hold 文档里仍提到但没进配额表，判为解析漏行、本次不剪: {held}")
    if graced:
        _log(f"prune-grace 首次缺席（未满 {PRUNE_GRACE_SECONDS // 3600}h），先挂起不剪: {graced}")
    if pruned:
        _log(f"prune wild not in quota/zen: {pruned}")
    if not dry_run:
        _save_prune_pending(pending)

    # 存量模型的上下文/档位自动同步（registry 手工实测 > models.dev > opencodex；ultra 等无需发版）
    if modelsdev_map or upstream_map:
        _reg = load_reasoning_overrides()
        updated = 0
        for m in to_keep:
            slug = m.get("slug", "")
            bare = slug[:-3] if slug.endswith("-go") else (slug[:-4] if slug.endswith("-zen") else slug)
            lookup = bare[:-5] if bare.endswith("-free") else bare
            md = modelsdev_map.get(bare) or modelsdev_map.get(lookup)
            up = None
            for key in (slug, bare, lookup, bare + "-go", lookup + "-go"):
                if key in upstream_map:
                    up = upstream_map[key]
                    break
            # context：手工覆盖 > models.dev > opencodex
            ctx = CONTEXT_OVERRIDES.get(lookup) or (md[0] if md else 0) or (up[0] if up else 0)
            if ctx and m.get("context_window") != ctx:
                m["context_window"] = ctx
                m["max_context_window"] = ctx
                updated += 1
            # modalities：models.dev 为准，过 Codex 白名单（video/pdf 会炸整个 models.json）
            san = _sanitize_modalities(md[2]) if md else None
            if san and m.get("input_modalities") != san:
                m["input_modalities"] = san
                updated += 1
            # 显示名：models.dev 官方 name 为准（手工 override 除外），改名无需发版
            disp_suffix = "Zen" if slug.endswith("-zen") else ("Go" if slug.endswith("-go") else None)
            md_exact = modelsdev_map.get(bare)
            if disp_suffix and md_exact and len(md_exact) > 3:
                want_name = _display_name_for(bare, disp_suffix, md_exact[3])
                if want_name and m.get("display_name") != want_name:
                    _log(f"显示名 {slug}: {m.get('display_name')!r} -> {want_name!r} (models.dev)")
                    m["display_name"] = want_name
                    updated += 1
            # 档位：registry 手工实测条目不动；否则 models.dev > opencodex
            if not (_reg.get(bare) or _reg.get(lookup)):
                levels = (md[1] if md else None) or (up[1] if up else None)
                if levels and [lv.get("effort") for lv in m.get("supported_reasoning_levels", [])] != levels:
                    descs = {
                        "low": "Fast responses with lighter reasoning",
                        "medium": "Balanced reasoning for everyday tasks",
                        "high": "Extra high reasoning depth for complex problems",
                        "xhigh": "Extended reasoning depth for harder tasks",
                        "max": "Maximum reasoning depth for the hardest problems",
                        "none": "No reasoning",
                        "ultra": "Maximum reasoning with automatic task delegation",
                    }
                    m["supported_reasoning_levels"] = [{"effort": lv, "description": descs.get(lv, lv)} for lv in levels]
                    m["default_reasoning_level"] = levels[0] if levels else m.get("default_reasoning_level", "high")
                    updated += 1
        if updated:
            _log(f"auto context/reasoning updated {updated} fields (models.dev/registry)")

    # 三层档位一致：目录 -> 代理档位表 + 桌面端档位白名单（2026-09-10 加）
    # 放在刷新之后：即使模型没增删、只有档位变化，这两层也会跟着同步。
    sync_derived(to_keep + to_add, dry_run=dry_run)

    if not to_add and not pruned:
        # 即使无增删，也可能有上下文/档位更新
        try:
            if 'updated' in locals() and updated > 0:
                pass
            else:
                _log("no new models to add and no prune")
                return 0
        except:
            _log("no new models to add and no prune")
            return 0

    if to_add:
        _log(f"will add {len(to_add)} models:")
        for e in to_add:
            _log(f"  + {e['slug']} (priority {e['priority']}) vis={e['visibility']}")

    if dry_run:
        _log(f"dry-run, would prune {len(pruned)} and add {len(to_add)}, not writing")
        return len(to_add)

    # backup
    bak = CODEX_HOME / f"models.json.bak.{time.strftime('%Y%m%d%H%M%S')}"
    if MODELS_JSON.exists():
        bak.write_bytes(MODELS_JSON.read_bytes())
        _log(f"backup -> {bak}")

    j["models"] = to_keep + to_add
    # re-assign priorities 1..N to keep order stable by quota order + Zen after Go
    quota_order = {rid:i for i,rid in enumerate(ids)}
    zen_order = {rid:100+i for i,rid in enumerate(zen_ids)}
    def prio_key(m):
        slug=m.get("slug","")
        if slug.endswith("-zen"):
            bare=slug[:-4]
            return (zen_order.get(bare, 999), m.get("priority",999))
        bare=slug[:-3] if slug.endswith("-go") else slug
        return (quota_order.get(bare, 999), m.get("priority",999))
    j["models"].sort(key=prio_key)
    # re-number priorities sequentially
    for i,m in enumerate(j["models"], start=1):
        m["priority"]=i
        bare_go = m["slug"][:-3] if m["slug"].endswith("-go") else None
        bare_zen = m["slug"][:-4] if m["slug"].endswith("-zen") else None
        if bare_go and bare_go in quota_bare:
            m["visibility"]="list"
        if bare_zen and bare_zen in zen_bare:
            m["visibility"]="list"
    tmp = MODELS_JSON.with_suffix(".tmp")
    tmp.write_text(json.dumps(j, ensure_ascii=False, indent=2) + "\n")
    tmp.replace(MODELS_JSON)
    _log(f"wrote {MODELS_JSON} ({len(j['models'])} total) pruned {len(pruned)} added {len(to_add)}")
    return len(to_add)

# ---------------------------------------------------------------------------
# 三层档位一致（2026-09-10）
#   目录层 models.json                                  <- models.dev / 覆盖层（上面主流程）
#   代理层 reasoning_registry.json                       <- 由目录生成（vision_proxy 读它 clamp）
#   桌面层 config.toml [desktop] enabled-reasoning-efforts <- 由目录生成（决定滑杆显示几档）
# 以前三层各写各的：目录声明 3 档、滑杆只显示 2 档、发出去还可能被压成第 2 档。
# ---------------------------------------------------------------------------

def _bare_id(slug):
    """slug 去掉 -go / -zen 后缀 = 发给网关的真实模型 id。"""
    if slug.endswith("-go"):
        return slug[:-3]
    if slug.endswith("-zen"):
        return slug[:-4]
    return slug

def _levels_of(m):
    return [lv.get("effort") for lv in (m.get("supported_reasoning_levels") or [])
            if isinstance(lv, dict) and lv.get("effort")]

def _toml_section_span(lines, section):
    """返回 [section] 段的行号范围 (start, end)；end = 下一段起始行或文件末尾。"""
    start = None
    for i, ln in enumerate(lines):
        if ln.strip() == f"[{section}]":
            start = i
            break
    if start is None:
        return None
    for j in range(start + 1, len(lines)):
        s = lines[j].strip()
        if s.startswith("[") and s.endswith("]"):
            return (start, j)
    return (start, len(lines))

def write_reasoning_registry(models, dry_run=False):
    """把目录里的档位表落成代理读的 reasoning_registry.json（生成物）。

    目录优先；旧文件里有、目录里已经没有的条目保留（不删数据，避免误伤隐藏模型）。
    """
    path = _reasoning_registry_path()
    old = _read_json(path, {})
    fresh = {}
    for m in models:
        slug = str(m.get("slug", ""))
        lv = _levels_of(m)
        if slug and lv:
            fresh[_bare_id(slug)] = lv
    merged = {k: v for k, v in old.items() if k not in fresh}
    merged.update(fresh)
    if merged == old:
        return 0
    if dry_run:
        _log(f"[dry-run] reasoning_registry.json: 目录档位 {len(fresh)} 条，"
             f"覆盖历史 {len(set(fresh) & set(old))} 条，新增 {len(set(fresh) - set(old))} 条")
        return len(fresh)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(merged, ensure_ascii=False, indent=1) + "\n")
        tmp.replace(path)
        _log(f"reasoning_registry.json <- 目录生成 {len(fresh)} 条"
             f"（保留历史 {len(merged) - len(fresh)} 条）")
    except Exception as e:
        _log(f"reasoning_registry 写失败: {e!r}")
        return 0
    return len(fresh)

def _effective_whitelist(models):
    """桌面端应放开的档位：app 默认档 + 目录里出现过的全部档位（含 max）。"""
    union = set(APP_DEFAULT_EFFORTS)
    for m in models:
        union |= set(_levels_of(m))
    union.add("persistent")
    return [e for e in EFFORT_ORDER if e in union]

def _configured_whitelist():
    """读 config.toml [desktop] 里的白名单；没写或读不到返回 None（= 走 app 默认）。"""
    cfg = CODEX_HOME / "config.toml"
    try:
        if not cfg.exists():
            return None
        lines = cfg.read_text().splitlines()
    except Exception:
        return None
    span = _toml_section_span(lines, "desktop")
    if not span:
        return None
    start, end = span
    for i in range(start + 1, end):
        mm = re.match(r"\s*" + re.escape(DESKTOP_WHITELIST_KEY) + r"\s*=\s*(.+)$", lines[i])
        if mm:
            try:
                v = json.loads(mm.group(1).strip())
                return v if isinstance(v, list) else None
            except Exception:
                return None
    return None

def sync_desktop_whitelist(models, dry_run=False):
    """把白名单写进 config.toml [desktop]，让滑杆不再被默认值截掉 max 档。"""
    want = _effective_whitelist(models)
    cfg = CODEX_HOME / "config.toml"
    if not cfg.exists():
        _log("config.toml 不存在，跳过桌面档位白名单同步")
        return False
    try:
        text = cfg.read_text()
    except Exception as e:
        _log(f"config.toml 读取失败: {e!r}")
        return False
    lines = text.splitlines()
    span = _toml_section_span(lines, "desktop")
    if not span:
        _log("config.toml 没有 [desktop] 段，跳过桌面档位白名单同步")
        return False
    start, end = span
    newline = f"{DESKTOP_WHITELIST_KEY} = {json.dumps(want)}"
    target = None
    for i in range(start + 1, end):
        if re.match(r"\s*" + re.escape(DESKTOP_WHITELIST_KEY) + r"\s*=", lines[i]):
            target = i
            break
    if target is not None:
        if lines[target].strip() == newline:
            return False
        lines[target] = newline
    else:
        lines.insert(end, newline)
    out = "\n".join(lines) + ("\n" if text.endswith("\n") else "")
    if dry_run:
        _log(f"[dry-run] config.toml [desktop] {newline}")
        return True
    try:
        bak = cfg.parent / f"config.toml.bak.{time.strftime('%Y%m%d%H%M%S')}"
        bak.write_text(text)
        tmp = cfg.with_suffix(".tmp")
        tmp.write_text(out)
        tmp.replace(cfg)
    except Exception as e:
        _log(f"config.toml 写入失败: {e!r}")
        return False
    _log(f"config.toml [desktop] {newline}（备份 {bak.name}）")
    return True

def validate_catalog(models, modelsdev_map=None):
    """一致性自检：网关 id 对不对、档位声明有没有、桌面白名单够不够。返回问题列表。"""
    issues = []
    md = modelsdev_map if modelsdev_map is not None else (fetch_modelsdev() or {})
    overrides = load_reasoning_overrides()
    for m in models:
        slug = str(m.get("slug", ""))
        if not slug:
            continue
        bare = _bare_id(slug)
        lv = _levels_of(m)
        info = md.get(bare)
        want_prov = "opencode" if slug.endswith("-zen") else "opencode-go"
        if info is None:
            issues.append(f"{slug}: 网关 id {bare!r} 在 models.dev 查不到，很可能 401 Model not supported")
        elif len(info) > 4 and info[4] != want_prov:
            issues.append(f"{slug}: id {bare!r} 在 {info[4]} 里，但这是 {want_prov} 的模型")
        if not lv:
            issues.append(f"{slug}: 没声明任何档位")
        unknown = [x for x in lv if x not in EFFORT_ORDER]
        if unknown:
            issues.append(f"{slug}: 档位 {unknown} 不在 Codex 有效档位表里")
        ov = overrides.get(bare)
        if ov and list(ov) != list(lv):
            issues.append(f"{slug}: 覆盖层 {list(ov)} 与目录 {lv} 不一致（以目录为准）")
    need = set()
    for m in models:
        need |= set(_levels_of(m))
    have = set(_configured_whitelist() or APP_DEFAULT_EFFORTS)
    missing = [e for e in EFFORT_ORDER if e in need and e not in have]
    if missing:
        issues.append(f"桌面白名单缺 {missing}：这些档位不会出现在滑杆上")
    return issues

def sync_derived(models, dry_run=False):
    """目录 -> 代理档位表 + 桌面白名单，并打印一致性自检。"""
    write_reasoning_registry(models, dry_run=dry_run)
    sync_desktop_whitelist(models, dry_run=dry_run)
    issues = validate_catalog(models)
    for it in issues:
        _log(f"[一致性] {it}")
    if not issues:
        _log("[一致性] 目录 / 代理 / 桌面三层档位一致")
    return issues

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sync", action="store_true", help="fetch and merge")
    ap.add_argument("--force", action="store_true", help="ignore TTL")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list", action="store_true", help="print remote ids and exit")
    ap.add_argument("--sync-derived", action="store_true",
                    help="only regenerate reasoning_registry.json + config.toml whitelist from models.json")
    args = ap.parse_args()
    if args.list:
        ids = fetch_remote_ids() or load_cache() or {"ids": FALLBACK_IDS}
        if isinstance(ids, dict):
            ids = ids["ids"]
        for i in ids:
            print(i)
        return
    if args.sync or args.dry_run:
        sync(force=args.force, dry_run=args.dry_run)
        return
    if args.sync_derived:
        j = load_models_json()
        issues = sync_derived(j.get("models", []), dry_run=args.dry_run)
        sys.exit(1 if issues else 0)
    ap.print_help()

if __name__ == "__main__":
    main()
