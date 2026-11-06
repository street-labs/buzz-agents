#!/usr/bin/env bash
# An agent must never be summoned by its own message. Its reply quoting
# "@name" used to re-summon it, once per reply. Run: bash test-filter-self.sh
set -u
cd "$(dirname "$0")"
bash -n agent-watcher.sh || { echo "FAIL: agent-watcher.sh does not parse"; exit 1; }
T=$(mktemp -d)
FILTER="$(python3 -c '
import re,sys
s = open("agent-watcher.sh").read()
print(re.search(r"^FILTER=\x27(.*?)^\x27", s, re.S | re.M).group(1))')"
ME=aaaa; PEER=bbbb; OWNER=ffff
: > "$T/seen"; : > "$T/threads"; printf '%s\n%s\n' "$ME" "$PEER" > "$T/peers"; : > "$T/assist"
msgs='[{"id":"m1","pubkey":"aaaa","content":"I will pick up the next @builder start message","tags":[]},
       {"id":"m2","pubkey":"bbbb","content":"@builder start SR-1","tags":[]},
       {"id":"j1","pubkey":"aaaa","content":"@builder job \"alpha build\" finished rc=0. Log: /x","tags":[]},
       {"id":"j2","pubkey":"aaaa","content":"@builder job \"alpha build\" stopped without a verdict - its shell died. Log: /x","tags":[]}]'
out="$(printf '%s' "$msgs" | python3 -c "$FILTER" "$T/seen" "$OWNER" builder "$T/threads" "$T/peers" "$ME" 0 "$T/assist" "" | cut -f1)"
fail=0
printf '%s\n' "$out" | grep -qx m1 && { echo "FAIL: own message summoned the agent"; fail=1; }
printf '%s\n' "$out" | grep -qx m2 || { echo "FAIL: peer @summon was dropped"; fail=1; }
# agent-job.sh posts a job's outcome with the agent's own key; that post must wake it.
printf '%s\n' "$out" | grep -qx j1 || { echo "FAIL: own job-finished post was dropped"; fail=1; }
printf '%s\n' "$out" | grep -qx j2 || { echo "FAIL: own job-killed post was dropped"; fail=1; }
# "@builder" is a generic alias, but not when the p-tag says the message is for a peer:
# every other agent used to take it as a direct summon, wake, and answer "that's for builder".
msgs='[{"id":"p1","pubkey":"ffff","content":"@builder how are these recorded","tags":[["p","bbbb"]]},
       {"id":"p2","pubkey":"ffff","content":"@builder ask brain about it","tags":[["p","bbbb"]]},
       {"id":"p3","pubkey":"ffff","content":"@brain and @builder take a look","tags":[["p","bbbb"],["p","aaaa"]]},
       {"id":"p4","pubkey":"ffff","content":"brain, what do you think","tags":[]}]'
out="$(printf '%s' "$msgs" | python3 -c "$FILTER" "$T/seen" "$OWNER" brain "$T/threads" "$T/peers" "$ME" 0 "$T/assist" "" | cut -f1)"
printf '%s\n' "$out" | grep -qx p1 && { echo "FAIL: @builder p-tagged to a peer summoned another agent"; fail=1; }
printf '%s\n' "$out" | grep -qx p2 && { echo "FAIL: bare name in a message p-tagged to a peer summoned the agent"; fail=1; }
printf '%s\n' "$out" | grep -qx p3 || { echo "FAIL: multi-summon that tags this agent was dropped"; fail=1; }
printf '%s\n' "$out" | grep -qx p4 || { echo "FAIL: bare-name address with no peer tag was dropped"; fail=1; }
rm -rf "$T"
[ "$fail" -eq 0 ] && echo "ok"
exit "$fail"
