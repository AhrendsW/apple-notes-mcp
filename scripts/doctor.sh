#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/AppleNotesMCP"
CONFIG="$HOME/.codex/config.toml"
RUN_SMOKE=1
FAILED=0

for arg in "$@"; do
  case "$arg" in
    --skip-smoke)
      RUN_SMOKE=0
      ;;
    -h|--help)
      echo "Usage: scripts/doctor.sh [--skip-smoke]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

pass() {
  echo "PASS $1"
}

warn() {
  echo "WARN $1"
}

fail() {
  echo "FAIL $1" >&2
  FAILED=1
}

if command -v swift >/dev/null 2>&1; then
  SWIFT_VERSION="$(swift --version 2>&1 | head -n 1)"
  pass "swift available: $SWIFT_VERSION"
else
  fail "swift is not on PATH"
fi

if [[ -d /System/Applications/Notes.app ]]; then
  pass "Apple Notes app found"
else
  fail "Apple Notes app not found at /System/Applications/Notes.app"
fi

if [[ -x "$BIN" ]]; then
  pass "release binary exists: $BIN"
else
  fail "release binary missing; run scripts/build-release.sh"
fi

if command -v codex >/dev/null 2>&1; then
  pass "codex CLI available"
else
  warn "codex CLI is not on PATH; cannot verify CLI command availability"
fi

if [[ -f "$CONFIG" ]]; then
  if grep -Fq "$BIN" "$CONFIG" || grep -Fq "[mcp_servers.apple-notes]" "$CONFIG"; then
    pass "Codex config mentions apple-notes or this binary"
  else
    warn "Codex config exists but does not mention apple-notes or $BIN"
  fi
else
  warn "Codex config not found at $CONFIG"
fi

if [[ "$RUN_SMOKE" -eq 1 && -x "$BIN" ]]; then
  SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apple-notes-mcp-doctor.XXXXXX")"
  SMOKE_CONFIG="$SMOKE_DIR/config.json"
  SMOKE_STDIN="$SMOKE_DIR/stdin"
  SMOKE_STDOUT="$SMOKE_DIR/stdout.log"
  SMOKE_STDERR="$SMOKE_DIR/stderr.log"
  printf '{"databasePath":"%s/index.sqlite","logPath":"%s/server.log","syncLockPath":"%s/sync.lock","logLevel":"error"}\n' \
    "$SMOKE_DIR" "$SMOKE_DIR" "$SMOKE_DIR" > "$SMOKE_CONFIG"
  mkfifo "$SMOKE_STDIN"
  REQUESTS='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"doctor","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"notes_health","arguments":{}}}
'
  APPLE_NOTES_MCP_CONFIG="$SMOKE_CONFIG" "$BIN" < "$SMOKE_STDIN" > "$SMOKE_STDOUT" 2>"$SMOKE_STDERR" &
  SMOKE_PID=$!
  exec 3>"$SMOKE_STDIN"
  printf '%s' "$REQUESTS" >&3

  OUTPUT=""
  for _ in {1..50}; do
    OUTPUT="$(cat "$SMOKE_STDOUT" 2>/dev/null || true)"
    if [[ "$OUTPUT" == *'"status"'* ]]; then
      break
    fi
    sleep 0.1
  done

  exec 3>&-
  wait "$SMOKE_PID"
  STATUS=$?
  OUTPUT="$(cat "$SMOKE_STDOUT" 2>/dev/null || true)"
  STDERR="$(cat "$SMOKE_STDERR" 2>/dev/null || true)"
  rm -rf "$SMOKE_DIR"
  if [[ "$STATUS" -eq 0 && "$OUTPUT" == *'"id":2'* && "$OUTPUT" == *'"status"'* ]]; then
    pass "notes_health smoke test returned a response"
  else
    warn "notes_health smoke test did not return the expected response"
    [[ -n "$STDERR" ]] && warn "smoke stderr was non-empty"
  fi
elif [[ "$RUN_SMOKE" -eq 0 ]]; then
  warn "notes_health smoke test skipped"
fi

exit "$FAILED"
