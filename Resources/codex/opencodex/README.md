# OpenCodex 集成 - 一键副本无需全局安装

本目录为 `opencodex` 的本地内嵌集成，复用其转接层替代手写 `vision_proxy`。

## 原理

* 不执行 `npm install -g @bitkyc08/opencodex`，而是在 `~/ .local/share/opencodex` 做 **用户级本地安装**：

  ```bash
  npm install @bitkyc08/opencodex --prefix ~/.local/share/opencodex
  ~/.local/share/opencodex/node_modules/.bin/ocx start --port 19100
  ```

  或 `npx --yes @bitkyc08/opencodex` 按需拉取（离线则用已缓存）。
* 配置写入 `~/.opencodex/config.json`（`providers.opencode-go` 指向 `https://opencode.ai/zen/go`），`Codex` 的 `base_url=http://127.0.0.1:19100` 保持不变。
* `Go 模型` 的 `context_window / 推理档位` 由 `opencodex` 实时发现，无需手写 `models.json 1M/202k`；本地 `model_discovery.py` 保留作为 Widget 配额图的数据源，双写兼容。

## 文件

* `config-template.json` - opencodex providers 模板（Go + DeepSeek + GLM）
* `launch.sh` - 本地启动脚本（优先 ocx，缺失则自动安装）
* `install.sh` - 首次安装脚本（npm/bun）
