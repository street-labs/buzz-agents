#!/usr/bin/env bash
# Handling a message marks every earlier message in its thread seen. An untagged
# question skipped while the thread was muted, then a bare "@builder" re-tag, used to
# get answered twice. Run: bash test-earlier-seen.sh
set -u
cd "$(dirname "$0")"
bash -n agent-watcher.sh || { echo "FAIL: agent-watcher.sh does not parse"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
extract() { python3 -c '
import re,sys
s = open("agent-watcher.sh").read()
m = re.search(r"^" + sys.argv[1] + r"=\x27(.*?)^\x27", s, re.S | re.M)
print(m.group(1) if m else "")' "$1"; }
FILTER="$(extract FILTER)"; EARLIER="$(extract EARLIER_IN_THREAD)"
[ -n "$EARLIER" ] || { echo "FAIL: EARLIER_IN_THREAD not found"; exit 1; }
ME=aaaa; OWNER=ffff
thread='[{"id":"r","pubkey":"ffff","content":"@builder do SR-1","tags":[],"created_at":1},
         {"id":"q","pubkey":"ffff","content":"why is it slow?","tags":[["e","r","","root"]],"created_at":2},
         {"id":"t","pubkey":"ffff","content":"@builder","tags":[["e","r","","root"]],"created_at":3},
         {"id":"later","pubkey":"ffff","content":"one more","tags":[["e","r","","root"]],"created_at":4}]'
# Worker handled "t": it claims t, then sweeps the thread.
echo t > "$T/seen"; echo r > "$T/threads"; echo "$ME" > "$T/peers"; : > "$T/assist"
printf '%s' "$thread" | python3 -c "$EARLIER" t >> "$T/seen"
out="$(printf '%s' "$thread" | python3 -c "$FILTER" "$T/seen" "$OWNER" builder "$T/threads" "$T/peers" "$ME" 0 "$T/assist" "" | cut -f1)"
fail=0
printf '%s\n' "$out" | grep -qx q && { echo "FAIL: skipped question answered again after re-tag"; fail=1; }
printf '%s\n' "$out" | grep -qx later || { echo "FAIL: message after the handled one was swallowed"; fail=1; }
[ "$(printf '%s' "$thread" | python3 -c "$EARLIER" missing)" = "" ] || { echo "FAIL: unknown id marked messages"; fail=1; }
[ "$fail" = 0 ] && echo "all earlier-seen tests passed" || exit 1
