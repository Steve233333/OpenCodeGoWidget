#!/bin/zsh
# 步骤：10. 汇总
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 10. 汇总
# ---------------------------------------------------------------------------
if [[ "$SKIP_PATCH" -eq 1 ]]; then
  PATCH_TEXT="已跳过"
elif [[ "$PATCH_OK" -eq 1 ]]; then
  PATCH_TEXT="已完成（~/Applications/ChatGPT-Patched.app）"
else
  PATCH_TEXT="失败，请查看 ~/.codex/picker-patch/patch.log"
fi

if [[ "$MODE" == "update" ]]; then
  SUMMARY=$'更新完成 ✅\n\n可用模型：'"$MODEL_COUNT"$' 个\n默认模型：'"$DEFAULT_MODEL"$'\n双开副本：'"$PATCH_TEXT"$'\n\n说明：已用现有 Key 复用更新配置/模板/本地代理/补丁脚本，无需重填 Key。\n看图：不再需要视觉 Key，图片由模型原生处理（缺视觉的模型发图会报错，换有视觉的模型即可）。\n下一步：如副本在运行请重启生效；日志：'"$LOG"
else
  SUMMARY=$'安装完成 ✅\n\n可用模型：'"$MODEL_COUNT"$' 个\n默认模型：'"$DEFAULT_MODEL"$'\n双开副本：'"$PATCH_TEXT"$'\n\n看图：不再需要视觉 Key，图片由模型原生处理（缺视觉的模型发图会报错，换有视觉的模型即可）。\n\n下一步：\n1. 如果副本已启动，先完全退出再重新打开 Codex（生效）。\n2. 可选：gh auth login -h github.com 登录 GitHub；git config --global user.name/email 设置身份。\n3. 日志：'"$LOG"
fi

log "$SUMMARY"
if [[ "$NONINTERACTIVE" -eq 0 ]]; then
  show_info "$SUMMARY"
fi

echo
echo "$SUMMARY"
echo
