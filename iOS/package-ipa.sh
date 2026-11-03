#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/iOS/build/Release-iphoneos/OpenCode Go.app"
OUTPUT="${1:-$HOME/Desktop/OpenCodeGoIOS-1.0.1-unsigned.ipa}"
STAGE="$(mktemp -d /tmp/opencodego-ipa.XXXXXX)"

cd "$ROOT/iOS"
./check.sh

mkdir -p "$STAGE/Payload"
/usr/bin/ditto "$APP" "$STAGE/Payload/OpenCode Go.app"

cd "$STAGE"
/usr/bin/zip -qry "$OUTPUT" Payload

echo "$OUTPUT"
shasum -a 256 "$OUTPUT"
