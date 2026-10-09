#!/usr/bin/env bash
# Tests for channel_context in agent-watcher.sh: the channel's purpose goes into the prompt.
# Extracts the function from the watcher so the test can't drift.
set -euo pipefail
cd "$(dirname "$0")"

eval "$(sed -n '/^channel_context() {/,/^}/p' agent-watcher.sh)"
type channel_context >/dev/null || { echo "FAIL: could not extract channel_context"; exit 1; }

STUB_OUT=""
BUZZ=stub_buzz
stub_buzz() { printf '%s' "$STUB_OUT"; }

fail=0
check() { # name, buzz output, expected
  STUB_OUT="$2"
  local out; out="$(channel_context c1)"
  if [ "$out" = "$3" ]; then echo "ok: $1"; else
    echo "FAIL: $1"; echo "  expected: $3"; echo "  got:      $out"; fail=1; fi
}

check "description -> section" '{"name":"ui-tests","description":"Improving UI tests.\nFlakiness."}' '

## This channel
This thread is in #ui-tests. Channel purpose: Improving UI tests. Flakiness.'
check "no description -> empty" '{"name":"general","description":""}' ''
check "not a member (null) -> empty" 'null' ''
check "relay down -> empty" '' ''

exit $fail
