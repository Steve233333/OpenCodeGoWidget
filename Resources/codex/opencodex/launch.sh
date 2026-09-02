#!/bin/bash
set -uo pipefail
OCX_PREFIX="$HOME/.local/share/opencodex"
OCX_BIN="$OCX_PREFIX/node_modules/.bin/ocx"
CONFIG="$HOME/.opencodex/config.json"
PORT="${1:-19100}"

# Ensure config exists
if [ ! -f "$CONFIG" ]; then
  echo "[opencodex] config not found at $CONFIG, run one-click installer first" >&2
  exit 1
fi

# Try local ocx, then npx, then vision_proxy fallback
if [ -x "$OCX_BIN" ]; then
  echo "[opencodex] launching via $OCX_BIN --port $PORT"
  exec "$OCX_BIN" start --port "$PORT" --host 127.0.0.1
elif command -v npx >/dev/null 2>&1; then
  echo "[opencodex] launching via npx"
  exec npx --yes @bitkyc08/opencodex start --port "$PORT" --host 127.0.0.1
else
  # Fallback to legacy vision_proxy
  VISION_DIR="$HOME/.local/share/agent-vision-toolkit"
  echo "[opencodex] ocx not found, fallback to vision_proxy at $VISION_DIR"
  exec python3 "$VISION_DIR/vision_proxy.py" --port "$PORT" --upstream https://api.deepseek.com/ --env-file "$HOME/.config/agent-vision-toolkit/env"
fi
