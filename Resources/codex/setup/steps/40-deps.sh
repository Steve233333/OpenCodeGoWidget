#!/bin/zsh
# 步骤：3. 依赖检查
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 3. 依赖检查
# ---------------------------------------------------------------------------
for tool in openssl security codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "缺少依赖：$tool。请先运行 xcode-select --install 安装命令行工具后重试。"
  fi
done
# clang 只用来"给副本编一个启动器"（注入 --user-data-dir）。包里已经带了预编译的通用二进制
# （resources/patch/launcher-universal，arm64+x86_64），所以没装命令行工具也能干活。
# 2026-09-19：新机器上装 CLT 经常卡在"无法从软件更新服务器获得"，故降级为可选依赖。
# 注意：clang 也不能只看 `command -v` —— 没装命令行工具时 /usr/bin/clang 同样是占位程序
# （和 python3 一个套路），必须真跑一次 `clang --version` 才能确认可用。
if ! command -v clang >/dev/null 2>&1 || ! clang --version >/dev/null 2>&1; then
  if [[ -f "$RES_DIR/patch/launcher-universal" ]]; then
    log "未找到 clang（没装命令行工具）：补丁将使用随包附带的预编译启动器"
  else
    die "缺少依赖：clang，且包里没有预编译启动器（resources/patch/launcher-universal）。请运行 xcode-select --install 后重试。"
  fi
fi
# python3 必须"真跑一次"才算通过（2026-09-19 新机实测教训）：
# macOS 没装命令行工具时 /usr/bin/python3 只是个占位程序 —— 执行它只弹"请求安装开发者工具"
# 然后失败退出，而 `command -v python3` 却能看到文件、检查形同虚设，后面所有 python 步骤
# 静默挂掉，最后报成一句驴唇不对马嘴的"请检查 key 是否有效"。
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'print(1)' >/dev/null 2>&1; then
  die "python3 不可用，没法生成配置（模型目录、config.toml 都靠它）。
二选一解决，装完用 python3 -V 能打印版本号，再回来点「配置」：
  A) 装 Python（推荐，不需要命令行工具）：双击安装包 python-3.x.x-macos*.pkg，一路下一步
  B) 或装 Xcode 命令行工具：终端执行 xcode-select --install，等它装完（约 1GB，5~15 分钟）
如果 B 弹出「不能安装该软件，因为当前无法从软件更新服务器获得」——
那是系统从 Apple 服务器下载失败（多半是 VPN/代理把 Apple 域名也走了代理），
可以先关掉 VPN 再试，或者直接用 A。"
fi
if [[ "$SKIP_PATCH" -eq 0 && ! -d "/Applications/ChatGPT.app" && ! -d "$HOME/Applications/ChatGPT.app" ]]; then
  die "没有找到 /Applications/ChatGPT.app 或 ~/Applications/ChatGPT.app。请先安装原版 Codex / ChatGPT 桌面版再运行。"
fi
