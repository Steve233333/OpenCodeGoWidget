#!/bin/bash
# 已停用（2026-09-02）：原来会把超过 8MB 的对话搬走，导致恢复时报错 file does not exist
# 现在不再搬了，电脑上的对话就留在原地。小组件更新时会顺手帮你把老的定时任务关掉，并把之前搬走的对话搬回来
# 如需重新启用，请恢复本文件的旧版本并重建 LaunchAgent
echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] archive-large-rollouts 已停用，不做任何操作" >> "${CODEX_HOME:-$HOME/.codex-deepseek}/failed_rollouts/archive.log" 2>/dev/null || true
exit 0
