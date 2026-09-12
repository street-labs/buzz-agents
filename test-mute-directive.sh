#!/usr/bin/env bash
# Tests for the [[WATCHER: mute]] directive parsing in agent-watcher.sh.
# Extracts the parser python heredoc from the watcher so the test can't drift.
set -euo pipefail
cd "$(dirname "$0")"

parser="$(sed -n '/<<.PY.$/,/^PY$/p' agent-watcher.sh | sed '1d;$d')"
[ -n "$parser" ] || { echo "FAIL: could not extract parser heredoc"; exit 1; }

run() { local f; f="$(mktemp)"; printf '%s' "$1" > "$f"; python3 -c "$parser" "$f"; rm -f "$f"; }

fail=0
check() { # name, input, expected_json
  local name="$1" input="$2" expected="$3" out
  out="$(run "$input")"
  if [ "$out" = "$expected" ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name"; echo "  expected: $expected"; echo "  got:      $out"; fail=1
  fi
}

# Bare mute: true silence - empty reply, mute action.
check "bare mute -> silent" '[[WATCHER: mute]]' '{"reply": "", "action": {"action": "mute", "instructions": ""}}'

# Text + mute: text kept, directive stripped.
check "text + mute -> text kept" 'here is the answer
[[WATCHER: mute]]' '{"reply": "here is the answer", "action": {"action": "mute", "instructions": ""}}'

# Bare fresh still gets the fallback text (never silently dropped).
check "bare fresh -> fallback text" '[[WATCHER: fresh]]' '{"reply": "Context lifecycle update scheduled.", "action": {"action": "fresh", "instructions": ""}}'

# Empty reply with no directive: stays empty (the reply guard handles re-prompting).
check "no directive, empty -> empty" '' '{"reply": "", "action": null}'

[ "$fail" = 0 ] && echo "all mute-directive tests passed" || exit 1
