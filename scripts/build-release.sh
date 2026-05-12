#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p .build/clang-module-cache .build/swiftpm-cache .build/swiftpm-config .build/swiftpm-security
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache"

echo "Building AppleNotesMCP release binary..."
swift build \
  --cache-path "$ROOT/.build/swiftpm-cache" \
  --config-path "$ROOT/.build/swiftpm-config" \
  --security-path "$ROOT/.build/swiftpm-security" \
  --manifest-cache local \
  --disable-sandbox \
  -c release

BIN="$ROOT/.build/release/AppleNotesMCP"
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: release binary was not created at $BIN" >&2
  exit 1
fi

echo "Release binary: $BIN"
