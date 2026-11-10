#!/usr/bin/env bash
# Tests for session_limit_until in agent-watcher.sh — the gate that diverts a turn onto the
# fallback harness when the primary reports a usage limit. Extracts the function from the
# watcher so the test can't drift.
#
# Claude Code has shipped at least three wordings for the same notice. Each time one lands
# unrecognised the fallback stops firing and the notice is posted to the channel as the
# turn's answer, with nothing in the log to say so — so every known wording is asserted here.
set -euo pipefail
cd "$(dirname "$0")"

fn="$(sed -n '/^session_limit_until() {/,/^}/p' agent-watcher.sh)"
[ -n "$fn" ] || { echo "FAIL: could not extract session_limit_until"; exit 1; }
eval "$fn"

fail=0

# The epoch itself moves with the run date — a reset time already past rolls to tomorrow —
# so assert on the wall clock in the notice's own zone, plus that it is still ahead of now.
check_reset() { # name, input, tz, expected HH:MM
  local name="$1" input="$2" tz="$3" expected="$4" epoch got
  epoch="$(session_limit_until "$input")"
  if [ -z "$epoch" ]; then
    echo "FAIL: $name"; echo "  expected a reset time, got nothing"; fail=1; return
  fi
  got="$(python3 -c '
import sys, datetime
from zoneinfo import ZoneInfo
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), ZoneInfo(sys.argv[2])).strftime("%H:%M"))
' "$epoch" "$tz")"
  if [ "$got" != "$expected" ]; then
    echo "FAIL: $name"; echo "  expected: $expected $tz"; echo "  got:      $got $tz"; fail=1
  elif [ "$epoch" -le "$(date +%s)" ]; then
    echo "FAIL: $name"; echo "  reset epoch $epoch is in the past"; fail=1
  else
    echo "ok: $name"
  fi
}

check_none() { # name, input
  local name="$1" input="$2" out
  out="$(session_limit_until "$input")"
  if [ -n "$out" ]; then
    echo "FAIL: $name"; echo "  expected nothing, got: $out"; fail=1
  else
    echo "ok: $name"
  fi
}

# The wording seen when this was written, 2026-08-31.
check_reset "session limit" \
  "You've hit your session limit · resets 3:10pm (Europe/London)" \
  "Europe/London" "15:10"

# The wording that broke it: live from 2026-10-09 to 2026-11-10, unrecognised throughout.
check_reset "5-hour limit" \
  "You've hit your 5-hour limit · resets 11:50am (Europe/London)" \
  "Europe/London" "11:50"

check_reset "weekly limit" \
  "You've hit your weekly limit · resets 9:00am (Asia/Tokyo)" \
  "Asia/Tokyo" "09:00"

# Midnight and noon are where a 12-hour clock is easiest to get wrong.
check_reset "12am rolls to 00:xx" \
  "You've hit your 5-hour limit · resets 12:30am (Asia/Tokyo)" \
  "Asia/Tokyo" "00:30"
check_reset "12pm stays at 12:xx" \
  "You've hit your 5-hour limit · resets 12:30pm (Asia/Tokyo)" \
  "Asia/Tokyo" "12:30"

# An ordinary turn must pass through untouched, including one that discusses limits.
check_none "ordinary reply" "Here is the answer you asked for."
check_none "reply mentioning a limit" "The API returned a rate limit error; I retried and it went through."

# No parseable reset time means no marker — better to post the notice than to strand the
# agent on the fallback behind a bogus clock.
check_none "limit notice, no reset time" "You've hit your 5-hour limit."
check_none "limit notice, unknown zone" \
  "You've hit your 5-hour limit · resets 11:50am (Mars/Olympus)"

[ "$fail" = 0 ] && echo "all session-limit tests passed" || exit 1
