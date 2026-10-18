#!/usr/bin/env bash
# Two fixes from the 2026-10 coffee-shop thrash, each verified against real behavior:
# 1. agent-job.sh serializes jobs per repo - a second job queues behind a live one
#    instead of racing it for the same simulator.
# 2. The watcher defers a stall auto-resume while a background job is live on the
#    thread, instead of relaunching the harness mid-job.
# Run: bash test-job-serialization.sh
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
export HOME="$T/home"
export AGENT_NAME=builder
export BUZZ_CHANNEL=chan1 BUZZ_THREAD=root1
JOBS="$HOME/.buzz/agents/builder/jobs"
mkdir -p "$HOME/.buzz/agents/builder" "$T/bin" "$T/repo"
git -C "$T/repo" init -q 2>/dev/null

# stand-in for the buzz CLI: records sends, no-ops reactions
cat > "$T/bin/buzz" <<'INNER'
#!/bin/sh
if [ "$1" = reactions ]; then exit 0; fi
echo "$*" >> "$SENT"
INNER
chmod +x "$T/bin/buzz"
export BUZZ="$T/bin/buzz" SENT="$T/sent.log"; : > "$SENT"

fail() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
FAILS=0

# --- 1. per-repo, per-tool serialization ---------------------------------
cd "$T/repo"
t0=$(date +%s)
"$DIR/agent-job.sh" --label "ios build" -- bash -c 'xcodebuild build; sleep 4' >/dev/null 2>&1
"$DIR/agent-job.sh" --label "ios verify" -- bash -c 'xcodebuild verify; echo ran > '"$T"'/second-ran' >/dev/null 2>&1
# a different tool must NOT queue behind the xcodebuild lock
"$DIR/agent-job.sh" --label "rust build" -- bash -c 'cargo build; echo now > '"$T"'/other-tool-ran' >/dev/null 2>&1
"$DIR/agent-job.sh" --label deploy -- bash -c 'deploy --all; echo now > '"$T"'/unrelated-ran' >/dev/null 2>&1
sleep 1
[ -f "$T/other-tool-ran" ] || fail "different-tool job wrongly queued behind the xcodebuild lock"
[ -f "$T/unrelated-ran" ] || fail "non-build job wrongly queued behind the xcodebuild lock"
# while the xcodebuild job runs, exactly one lock exists and the queued one has not started
locks="$(ls "$JOBS"/repo-*-tool-xcodebuild.lock 2>/dev/null | wc -l | tr -d ' ')"
[ "$locks" = "1" ] || fail "expected exactly 1 xcodebuild lock while job 1 runs, saw $locks"
[ -f "$T/second-ran" ] && fail "same-tool job 2 started while job 1 held the lock"
# job 2 must run after job 1 finishes (~4s), not before
for _ in $(seq 1 30); do [ -f "$T/second-ran" ] && break; sleep 1; done
[ -f "$T/second-ran" ] || fail "job 2 never ran"
elapsed=$(( $(date +%s) - t0 ))
[ "$elapsed" -ge 3 ] || fail "job 2 did not queue behind job 1 (elapsed ${elapsed}s)"
# the lock is released when the holder exits
sleep 1
[ -z "$(ls "$JOBS"/repo-*tool-*.lock 2>/dev/null)" ] || fail "tool lock not released after holder exit"

# a stale lock (holder died) is stolen, not waited on. Compute the lock name
# exactly as agent-job.sh does (hash of the string, not a file path), so this
# test cannot pass vacuously against a name the runner never uses.
top="$(git -C "$T/repo" rev-parse --show-toplevel)"
real_lock="$JOBS/repo-$(printf %s "$top" | md5 -q)-tool-xcodebuild.lock"
rm -rf "$JOBS"/repo-*tool-*.lock; mkdir -p "$real_lock"; echo "pid=999999" > "$real_lock/pid"
t0=$(date +%s)
"$DIR/agent-job.sh" --label "steal" -- bash -c 'xcodebuild build' >/dev/null 2>&1
sleep 2  # detached job needs a moment to steal the stale lock
[ ! -f "$real_lock/pid" ] || fail "stale lock not stolen: $real_lock still present"
elapsed=$(( $(date +%s) - t0 ))
[ "$elapsed" -le 3 ] || fail "stale lock not stolen (waited ${elapsed}s)"

# --- 2. stall resume deferred while a job is live -------------------------
job_live_for_thread_src="$(sed -n '/^job_live_for_thread()/,/^}/p' "$DIR/agent-watcher.sh")"
[ -n "$job_live_for_thread_src" ] || { echo "FAIL: job_live_for_thread not found in agent-watcher.sh"; FAILS=$((FAILS+1)); }
eval "$job_live_for_thread_src"

# live job (pid alive, no rc): thread considered busy
sleep 30 & livapid=$!
printf 'thread=root9\npid=%s\n' "$livapid" > "$JOBS/1792000000-1.job"
job_live_for_thread root9 && echo "pass: live job -> thread busy" || fail "live job not detected as live"
kill "$livapid" 2>/dev/null; wait "$livapid" 2>/dev/null

# dead-pid job with no rc: NOT live (the killed-job case must still get a resume)
printf 'thread=root8\npid=999999\n' > "$JOBS/1792000001-2.job"
job_live_for_thread root8 && fail "dead-pid job wrongly counted as live" || echo "pass: dead-pid job -> not live"

# finished job (rc present): not live
printf 'thread=root7\npid=%s\n' "$livapid" > "$JOBS/1792000002-3.job"
printf '0' > "$JOBS/1792000002-3.rc"
job_live_for_thread root7 && fail "finished job wrongly counted as live" || echo "pass: finished job -> not live"

echo "----"
if [ "$FAILS" -eq 0 ]; then echo "all checks passed"; rm -rf "$T"; else echo "$FAILS failure(s)"; exit 1; fi
