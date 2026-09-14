#!/usr/bin/env bash
# An agent must never be summoned by its own message. Its reply quoting
# "@name" used to re-summon it, once per reply. Run: bash test-filter-self.sh
set -u
cd "$(dirname "$0")"
T=$(mktemp -d)
FILTER="$(python3 -c '
import re,sys
s = open("agent-watcher.sh").read()
print(re.search(r"^FILTER=\x27(.*?)^\x27", s, re.S | re.M).group(1))')"
ME=aaaa; PEER=bbbb; OWNER=ffff
: > "$T/seen"; : > "$T/threads"; printf '%s\n%s\n' "$ME" "$PEER" > "$T/peers"; : > "$T/assist"
msgs='[{"id":"m1","pubkey":"aaaa","content":"I will pick up the next @builder start message","tags":[]},
       {"id":"m2","pubkey":"bbbb","content":"@builder start SR-1","tags":[]}]'
out="$(printf '%s' "$msgs" | python3 -c "$FILTER" "$T/seen" "$OWNER" builder "$T/threads" "$T/peers" "$ME" 0 "$T/assist" "" | cut -f1)"
fail=0
printf '%s\n' "$out" | grep -qx m1 && { echo "FAIL: own message summoned the agent"; fail=1; }
printf '%s\n' "$out" | grep -qx m2 || { echo "FAIL: peer @summon was dropped"; fail=1; }
rm -rf "$T"
[ "$fail" -eq 0 ] && echo "ok"
exit "$fail"
