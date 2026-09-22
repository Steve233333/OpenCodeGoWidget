#!/bin/zsh
# 步骤：5. 生成 models.json
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 5. 生成 models.json（按 key 过滤 + 重排 priority）
# ---------------------------------------------------------------------------
MODEL_TMPL="$RES_DIR/templates/models.json"
MODELS_OUT="$CODEX_HOME/models.json"

# 按当前 Key 从模板生成（全新安装 / 列表被剪空时的回退）
gen_models_from_template() {
  python3 - "$MODEL_TMPL" "$MODELS_OUT" "$HAS_GO" "$HAS_DS" <<'PY'
import json, sys
src, dst, has_go, has_ds = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
data = json.load(open(src))
models = []
for m in data["models"]:
    is_go = m["slug"].endswith("-go") or m["slug"].endswith("-zen")
    if is_go and not has_go:
        continue
    if not is_go and not has_ds:
        continue
    models.append(m)
for i, m in enumerate(models, 1):
    m["priority"] = i
json.dump({"models": models}, open(dst, "w"), ensure_ascii=False, indent=2)
print(len(models))
PY
}

if [[ "$MODE" == "update" && -f "$MODELS_OUT" ]]; then
  log "更新模式：保留现有 models.json（自动更新），跳过模板"
  # 2026-09-14：按本次 Key 修剪不可用模型——没有 Go Key 就移除 -go/-zen，
  # 没有 DeepSeek Key 就移除官方模型。否则清掉 Key 后 Codex 里还能选到用不了的
  # 模型（比如无 Go Key 时选 deepseek-v4-flash-go，会直连 DeepSeek 报
  # "The supported API model names are ..."）。加回 Key 后配置/自动发现会恢复。
  python3 - "$MODELS_OUT" "$HAS_GO" "$HAS_DS" <<'PY'
import json, sys
dst, has_go, has_ds = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
try:
    data = json.load(open(dst))
except Exception as e:
    print(f"models.json 读取失败，保持原样：{e}")
    sys.exit(0)
models, removed = [], []
for m in data.get("models", []):
    slug = m.get("slug", "")
    is_go = slug.endswith("-go") or slug.endswith("-zen")
    if is_go and not has_go:
        removed.append(slug); continue
    if (not is_go) and not has_ds:
        removed.append(slug); continue
    models.append(m)
for i, m in enumerate(models, 1):
    m["priority"] = i
json.dump({"models": models}, open(dst, "w"), ensure_ascii=False, indent=2)
if removed:
    print(f"按 Key 修剪模型：移除 {len(removed)} 个当前不可用的模型（剩余 {len(models)} 个；加回 Key 后再配置会自动恢复）")
else:
    print("模型列表与当前 Key 匹配，无需修剪")
PY
  PRUNED_COUNT="$(python3 -c 'import json;print(len(json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || echo 0)"
  if [[ "$PRUNED_COUNT" -eq 0 ]]; then
    log "修剪后列表为空，按模板重新生成"
    gen_models_from_template > /dev/null
  fi
else
  gen_models_from_template > /dev/null
fi
MODEL_COUNT="$(python3 -c 'import json;print(len(json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || echo 0)"
AVAIL_SLUGS="$(python3 -c 'import json;print(" ".join(m["slug"] for m in json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || true)"
log "models.json 已生成：$MODEL_COUNT 个模型"
