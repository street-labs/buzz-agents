#!/usr/bin/env bash
# Loop cap on the normal path: a peer summon that is the 4th consecutive agent turn
# since the last human message is skipped. Run: bash test-turn-cap.sh
set -u
cd "$(dirname "$0")"
bash -n agent-watcher.sh || { echo "FAIL: agent-watcher.sh does not parse"; exit 1; }
T=$(mktemp -d)
FILTER="$(python3 -c '
import re,sys
s = open("agent-watcher.sh").read()
print(re.search(r"^FILTER=\x27(.*?)^\x27", s, re.S | re.M).group(1))')"
OWNER=ffff; BRAIN=aaaa; ENT=bbbb
: > "$T/seen"; : > "$T/threads"; : > "$T/assist"
printf '%s\n%s\n' "$BRAIN" "$ENT" > "$T/peers"
printf '%s\tbrain\n%s\tenterprise\n' "$BRAIN" "$ENT" > "$T/roster"
r='["e","h1","","root"]'
msgs='[{"id":"h1","pubkey":"ffff","created_at":1,"content":"@brain get the transcript","tags":[["p","aaaa"]]},
 {"id":"p1","pubkey":"aaaa","created_at":2,"content":"progress","tags":['$r']},
 {"id":"a1","pubkey":"aaaa","created_at":3,"content":"@enterprise transcript?","tags":['$r',["p","bbbb"]]},
 {"id":"a2","pubkey":"bbbb","created_at":4,"content":"@brain here","tags":['$r',["p","aaaa"]]},
 {"id":"a3","pubkey":"aaaa","created_at":5,"content":"@enterprise and the date?","tags":['$r',["p","bbbb"]]},
 {"id":"a4","pubkey":"bbbb","created_at":6,"content":"@brain Tuesday","tags":['$r',["p","aaaa"]]},
 {"id":"j1","pubkey":"aaaa","created_at":7,"content":"@brain job \"x\" finished rc=0","tags":['$r']}]'
run() { printf '%s' "$msgs" | python3 -c "$FILTER" "$T/seen" "$OWNER" "$1" "$T/threads" "$T/peers" "$2" 0 "$T/assist" "" "$T/roster" | cut -f1,6; }
fail=0
turns() { printf '%s\n' "$1" | awk -F'\t' -v id="$2" '$1==id{print $2}'; }
b="$(run brain "$BRAIN")"; e="$(run enterprise "$ENT")"
[ "$(turns "$b" a2)" = 2 ] || { echo "FAIL: a2 should be turn 2 (progress + reply = one turn), got $(turns "$b" a2)"; fail=1; }
[ "$(turns "$e" a3)" = 3 ] || { echo "FAIL: a3 should be turn 3, got $(turns "$e" a3)"; fail=1; }
[ "$(turns "$b" a4)" = 4 ] || { echo "FAIL: a4 should be turn 4, got $(turns "$b" a4)"; fail=1; }
[ "$(turns "$b" j1)" = 0 ] || { echo "FAIL: own job post must not be capped"; fail=1; }
cap=3
[ "$(turns "$e" a3)" -gt "$cap" ] && { echo "FAIL: 3rd turn capped"; fail=1; }
[ "$(turns "$b" a4)" -gt "$cap" ] || { echo "FAIL: 4th turn not capped"; fail=1; }
# No roster -> no cap (fail open, old behaviour).
nr="$(printf '%s' "$msgs" | python3 -c "$FILTER" "$T/seen" "$OWNER" brain "$T/threads" "$T/peers" "$BRAIN" 0 "$T/assist" "" "" | cut -f1,6)"
[ "$(turns "$nr" a4)" = 0 ] || { echo "FAIL: cap applied without a roster"; fail=1; }
grep -q 'agent_turns:-0}" -gt "${AGENT_TURN_CAP' agent-watcher.sh || { echo "FAIL: worker-path cap gate missing"; fail=1; }
rm -rf "$T"
[ "$fail" -eq 0 ] && echo "ok"
exit "$fail"
