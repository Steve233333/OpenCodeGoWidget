# 规矩：电脑和小组件必须一模一样

> 说大白话：你电脑上的配置是老大，小组件里的是小弟。小弟必须跟老大长得一模一样，每次打包前都要比一下，不一样就不让打包。这样就不会再出现改了电脑忘了改小组件的情况。

## 老大是谁

电脑上的 `~/.codex-deepseek/` 是老大：
- `config.toml` 怎么连、默认用哪个模型、记忆开不开
- `models.json` 有哪些模型、排什么顺序
- `vision_proxy.py` 怎么转发
- `scripts/archive-large-rollouts.sh` 搬不搬大对话（现在是不搬）

小组件里的 `Resources/codex/` 是小弟：
- `templates/config.toml`
- `templates/models.json`
- `vision/vision_proxy.py`
- `scripts/archive-large-rollouts.sh`
- `patch/patch.sh` 和 `patch/ent2.plist`

## 每次改完要做的事

1. 在电脑上改好，确认能用
2. 跑一遍 `Resources/codex/skills/codex-widget-sync/scripts/sync-from-home.sh`，会自动把老大的文件抄给小弟
3. 跑一遍 `scripts/check-drift.sh`，会自己比一遍，不一样就报错

## 打包前会自动检查

`build.sh` 开头会自己跑 `check-drift.sh`，不通过就直接停，不让你打出包。想跳过就加 `SKIP_DRIFT_CHECK=1 ./build.sh`，但不推荐。

## 如果两边不一样怎么办

看报错说的哪个文件不一样，就跑 `sync-from-home.sh` 同步一下，或者手把手改。改完再跑 `check-drift.sh` 直到显示“都没问题”。

## 平时不用记

只要记住：改配置只改电脑上的，改完跑一下同步脚本就行。打包会自动帮你检查。
