#!/bin/bash
set -euo pipefail
OCX_PREFIX="$HOME/.local/share/opencodex"
OCX_BIN="$OCX_PREFIX/node_modules/.bin/ocx"

if [ -x "$OCX_BIN" ]; then
  echo "[opencodex] already installed at $OCX_BIN ($("$OCX_BIN" --version 2>&1 | head -1))"
  exit 0
fi

echo "[opencodex] installing @bitkyc08/opencodex to $OCX_PREFIX ..."
mkdir -p "$OCX_PREFIX"

# Prefer npm, fallback to bun
if command -v npm >/dev/null 2>&1; then
  npm install @bitkyc08/opencodex --prefix "$OCX_PREFIX" --silent 2>&1 | tail -5 || npm install @bitkyc08/opencodex --prefix "$OCX_PREFIX" 2>&1 | tail -20
elif command -v bun >/dev/null 2>&1; then
  bun add @bitkyc08/opencodex --cwd "$OCX_PREFIX" 2>&1 | tail -5
else
  echo "[opencodex] ERROR: npm/bun not found, please install Node.js"
  exit 1
fi

if [ -x "$OCX_BIN" ]; then
  echo "[opencodex] installed successfully ($("$OCX_BIN" --version 2>&1 | head -1))"
else
  # npx fallback will download on first run
  echo "[opencodex] will use npx on demand (no local bin)"
fi
