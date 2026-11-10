#!/usr/bin/env bash
# Tests for session_limit_until() in agent-watcher.sh - the gate that spots a usage-limit
# notice in a turn's reply and switches to the fallback harness.
#
# This failed silently in production for a month: the gate matched the literal "hit your
# session limit", Claude Code changed the wording to "hit your 5-hour limit", and the
# notice sailed through as the turn's answer and got posted to #general. Nothing errored.
# Every wording seen in the wild is pinned here so the next one is a test failure.
#
# Extracts the function from the watcher so the test can't drift from the source.
set -euo pipefail
cd "$(dirname "$0")"

fn="$(sed -n '/^session_limit_until() {/,/^}$/p' agent-watcher.sh)"
[ -n "$fn" ] || { echo "FAIL: could not extract session_limit_until from agent-watcher.sh"; exit 1; }
eval "$fn"

fail=0

check_limit() { # name, reply text
  local name="$1" out
  out="$(session_limit_until "$2")"
  if [ -n "$out" ] && [ "$out" -gt 0 ] 2>/dev/null; then
    echo "ok: $name"
  else
    echo "FAIL: $name - expected a reset epoch, got '${out}'"; fail=1
  fi
}

check_not_limit() { # name, reply text
  local name="$1" out
  out="$(session_limit_until "$2")"
  if [ -z "$out" ]; then
    echo "ok: $name"
  else
    echo "FAIL: $name - expected no output, got '${out}'"; fail=1
  fi
}

# Every wording Claude Code has shipped for the notice.
check_limit "session limit"  "You've hit your session limit · resets 3:10pm (America/Indianapolis)"
check_limit "5-hour limit"   "You've hit your 5-hour limit · resets 11:50am (America/Indianapolis)"
check_limit "weekly limit"   "You've hit your weekly limit · resets 9:00am (America/Indianapolis)"

# A reply that merely talks about limits is not a notice.
check_not_limit "ordinary reply" "Pushed the fix. One caveat: the rate limit on that endpoint is 50/min."

# A notice with no parseable reset time cannot set a marker, so it must not claim one.
check_not_limit "no reset time" "You've hit your 5-hour limit."

[ "$fail" -eq 0 ] && echo "all session-limit tests passed"
exit "$fail"
