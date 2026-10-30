#!/usr/bin/env bash
# Tests the slot session lock in agent-watcher.sh. The regression: the owner file held
# the watcher's $$ (always alive, so a dead holder was never stolen) and the EXIT trap
# never fired under macOS /bin/bash 3.2, so every follow-up turn waited SLOT_SESSION_WAIT.
# Run: bash test-slot-session-lock.sh
set -u
cd "$(dirname "$0")"
eval "$(sed -n '/^spawn_worker() {/,/^}/p' agent-watcher.sh)"
type spawn_worker >/dev/null 2>&1 || { echo "FAIL: could not extract spawn_worker"; exit 1; }
owner_line="$(grep -m1 '> "$_slot_lock/owner"' agent-watcher.sh)"
[ -n "$owner_line" ] || { echo "FAIL: could not extract owner write"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
root_id=r1
# Stand-in worker: takes the lock the way worker does, then returns early.
worker() { _slot_lock="$tmp/.buzz-session"; mkdir "$_slot_lock"; eval "$owner_line"; sleep 1; return 0; }

spawn_worker & wpid=$!
sleep 0.5
holder="$(sed -n 's/^pid=//p' "$tmp/.buzz-session/owner")"
[ "$holder" = "$wpid" ] || { echo "FAIL: owner pid $holder, worker pid $wpid (watcher $$)"; exit 1; }
echo "ok: owner file records the worker subshell pid"
wait "$wpid"
[ ! -e "$tmp/.buzz-session" ] || { echo "FAIL: lock left behind after the worker returned"; exit 1; }
echo "ok: lock released when the worker returns"
