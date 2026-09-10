#!/usr/bin/env bash
set -euo pipefail

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COUNTER="$TMP/counter" CALLS="$TMP/calls"
echo 0 > "$COUNTER"

cursor-agent() {
  if [ "$1" = "create-chat" ]; then
    local n=$(( $(cat "$COUNTER") + 1 ))
    echo "$n" > "$COUNTER"
    echo "chat-$n"
  else
    printf '%s\n' "$*" >> "$CALLS"
    printf '{"result":"ok","session_id":"test"}\n'
  fi
}
export -f cursor-agent

source "$(cd "$(dirname "$0")" && pwd)/harness-adapters.sh"
invoke_cursor "$TMP/one" one model "" "$TMP" system
invoke_cursor "$TMP/two" two model "" "$TMP" system

grep -q -- '--resume chat-1' "$CALLS"
grep -q -- '--resume chat-2' "$CALLS"
echo "cursor isolation: ok"
