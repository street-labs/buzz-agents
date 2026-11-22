#!/usr/bin/env bash
# Verifies burn_nudge(): the per-thread cost governor that injects a wrap-up nudge
# once a thread's cumulative tokens cross THREAD_BURN_NUDGE_TOKENS, gated by a
# watermark so a compact/fresh buys quiet and continued burn re-arms it.
# Run: bash test-burn-nudge.sh [path-to-agent-watcher.sh]
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
WATCHER="${1:-$(cd "$(dirname "$0")" && pwd)/agent-watcher.sh}"
fail() { echo "FAIL: $1"; exit 1; }

bash -n "$WATCHER" || fail "agent-watcher.sh has a syntax error"
echo "ok: agent-watcher.sh parses"

# Extract just the burn-nudge functions (each ends at a bare '}' at column 0).
FUNCS="$(sed -n '/^get_burn_mark()/,/^}/p; /^set_burn_mark()/,/^}/p; /^burn_nudge()/,/^}/p' "$WATCHER")"
[ -n "$FUNCS" ] || fail "could not extract burn-nudge functions from $WATCHER"

T=$(mktemp -d)
export NUDGES="$T/nudges.tsv"; touch "$NUDGES"
export THREAD_BURN_NUDGE_TOKENS=1000
export AGENT_NAME=testbot
COSTS_FILE="$T/costs.tsv"; touch "$COSTS_FILE"   # stubbed get_cost reads this
get_cost() { awk -F'\t' -v r="$1" '$1==r{print $2":"$3; exit}' "$COSTS_FILE"; }
set_cost() { # $1=root $2=usd $3=tokens
  awk -F'\t' -v r="$1" '$1!=r' "$COSTS_FILE" > "$COSTS_FILE.tmp"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$COSTS_FILE.tmp"
  mv "$COSTS_FILE.tmp" "$COSTS_FILE"
}
eval "$FUNCS"

set_cost rootA 0.10 500
[ -z "$(burn_nudge rootA 2>/dev/null)" ] && echo "ok: under threshold stays silent" || fail "nudged below threshold"
[ -z "$(burn_nudge rootB 2>/dev/null)" ] && echo "ok: unknown thread stays silent" || fail "nudged thread with no cost row"
[ -z "$(burn_nudge rootC 2>/dev/null)" ] && echo "ok: zero-token row stays silent" || fail "nudged zero-token thread"
set_cost rootC 0.0 0
[ -z "$(burn_nudge rootC 2>/dev/null)" ] && echo "ok: zero-token row stays silent" || fail "nudged zero-token thread"

set_cost rootA 0.50 1000
OUT="$(burn_nudge rootA 2>/dev/null)"
grep -q "SYSTEM NOTE (cost control)" <<<"$OUT" || fail "no nudge at threshold"
grep -q "1000 tokens" <<<"$OUT" || fail "nudge missing token count"
[ "$(get_burn_mark rootA)" = "1000" ] || fail "watermark not recorded"
echo "ok: nudge fires at threshold and records watermark"

[ -z "$(burn_nudge rootA 2>/dev/null)" ] && echo "ok: watermark keeps it quiet" || fail "re-nudged before another increment"

set_cost rootA 0.60 1500
[ -z "$(burn_nudge rootA 2>/dev/null)" ] && echo "ok: partial increment stays quiet" || fail "re-nudged before a full increment"

set_cost rootA 1.00 2000
OUT="$(burn_nudge rootA 2>/dev/null)"
grep -q "2000 tokens" <<<"$OUT" || fail "no re-nudge after a full increment past watermark"
[ "$(get_burn_mark rootA)" = "2000" ] || fail "watermark did not advance"
echo "ok: re-arms after another full increment"

set_cost rootD 5.00 99999
OUT="$(burn_nudge rootD 2>/dev/null)"
grep -q "99999 tokens" <<<"$OUT" || fail "huge thread not nudged"
echo "ok: runaway thread gets nudged"

echo "ALL PASS"
