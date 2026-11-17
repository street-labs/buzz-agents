#!/usr/bin/env bash
# A summon posted in another channel that links a thread (buzz://...&thread=<root>)
# must not start a parallel turn while that thread's worker is live. Regression:
# 2026-11-16, a link posted in #general ran a second session beside the live one.
# Run: bash test-link-queue.sh
set -u
cd "$(dirname "$0")"
eval "$(sed -n '/^linked_busy_root() {/,/^}/p' agent-watcher.sh)"
type linked_busy_root >/dev/null 2>&1 || { echo "FAIL: could not extract linked_busy_root"; exit 1; }
# The dispatch-loop guard itself, from the line after the root lock check to its fi.
guard="$(sed -n '/^      if busy_link="\$(linked_busy_root/,/^      fi$/p' agent-watcher.sh)"
[ -n "$guard" ] || { echo "FAIL: could not extract the dispatch guard"; exit 1; }

WORKERS="$(mktemp -d)"; trap 'kill $live 2>/dev/null; rm -rf "$WORKERS"' EXIT
AGENT_NAME=t; link_waits=" "
target=0b4b9350aa; general=12e2a4f5bb
sleep 30 & live=$!
echo "$live" > "$WORKERS/root-$target.pid"

# Runs the guard the way the dispatch loop does; prints "spawn" if it falls through.
dispatch() {  # $1=content $2=own root
  local id=m1 root_id="$2" b64; b64="$(printf '%s' "$1" | base64)"
  for _ in 1; do eval "$guard"; echo spawn; done
}
fail=0
check() { [ "$2" = "$3" ] && echo "ok: $1" || { echo "FAIL: $1 (got '$2', want '$3')"; fail=1; }; }

link="@brain buzz://message?channel=2a6663ef&id=deadbeef&thread=$target"
check "thread= link to a live thread is queued" "$(dispatch "$link" "$general" | grep -c spawn)" 0
check "a summon waiting several polls is logged once" "$( { dispatch "$link" "$general"; dispatch "$link" "$general"; } | grep -c queued)" 1
check "id= link (no thread) to a live root is queued" "$(dispatch "see buzz://message?channel=c&id=$target" "$general" | grep -c spawn)" 0
check "&amp;-escaped link is queued" "$(dispatch "buzz://message?channel=c&amp;thread=$target" "$general" | grep -c spawn)" 0
check "link to an idle thread runs" "$(dispatch "buzz://message?channel=c&thread=feedface" "$general" | grep -c spawn)" 1
check "a message in the live thread itself is not blocked by its own link" "$(dispatch "buzz://message?channel=c&thread=$target" "$target" | grep -c spawn)" 1
check "plain summon runs" "$(dispatch "@brain hi" "$general" | grep -c spawn)" 1
kill "$live"; wait "$live" 2>/dev/null
check "runs once the linked turn ends" "$(dispatch "$link" "$general" | grep -c spawn)" 1
exit $fail
