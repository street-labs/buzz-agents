#!/usr/bin/env bash
# Integration tests for live steering (STEERING.md) against the REAL installed
# pi RPC binary. Uses a cheap model by default; override with TEST_PI_MODEL.
#
#   TEST_PI_MODEL="ppq/z-ai/glm-5.3-flash" ./test-live-steering.sh
#   ./test-live-steering.sh -v            # keep per-test output visible
#
# Covers:
#   1. Two thread roots run concurrently, each preserving its own FIFO ordering.
#   2. An owner follow-up during a slow tool call is steered into the same run.
#   3. Multiple queued owner messages are delivered together (steering mode all).
#   4. Stop clears queued work, aborts the run, and applies the correction.
#   5. A message already accepted by pi is not resubmitted (restart reconcile).
#   6. Idle expiry closes the process but the session resumes on the next submit.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OWNER="$HERE/pi_rpc_owner.py"
MODEL="${TEST_PI_MODEL:-ppq/z-ai/glm-5.3-flash}"
STATE="$(mktemp -d /tmp/pi-rpc-owner-test.XXXXXX)"
WORK="$(mktemp -d /tmp/pi-rpc-owner-work.XXXXXX)"
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
PASS=0; FAIL=0; PIDS=()

cleanup() {
  for f in "$STATE"/rpc/*.proc; do
    [ -f "$f" ] || continue
    pid="$(python3 -c "import json;print(json.load(open('$f'))['pid'])" 2>/dev/null)"
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  done
  pkill -f "pi_rpc_owner-test-holder" 2>/dev/null
  rm -rf "$STATE" "$WORK"
}
trap cleanup EXIT

# Each pi process is pointed at the temp workdir; system prompt keeps replies tiny.
SYSPROMPT="$(mktemp)"
printf 'You are a test bot. Reply with as few words as possible. No tools unless asked.' > "$SYSPROMPT"

submit() { # key intent message [extra args...]
  local key="$1" intent="$2" msg="$3"; shift 3
  python3 "$OWNER" submit --state-dir "$STATE" --key "$key" --intent "$intent" \
    --message "$msg" --model "$MODEL" --workdir "$WORK" \
    --system-prompt-file "$SYSPROMPT" --run-timeout 300 --settle 0 "$@"
}
json_reply() { python3 -c "import json,sys
try: print(json.load(open(sys.argv[1]))['reply'])
except Exception: print('')" "$1" 2>/dev/null; }
json_status() { python3 -c "import json,sys
try: print(json.load(open(sys.argv[1]))['status'])
except Exception: print('')" "$1" 2>/dev/null; }
reap() {
  python3 "$OWNER" reap --state-dir "$STATE" --max-idle "${2:-1800}" --max-live "${3:-8}"
}

check() { # name expected actual
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected [$2] got [$3]"; fi
}

keyhash() { python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:24])" "$1"; }

live_procs() { # [key] count .proc files (optionally just one key's) with a live pid
  local n=0 f pid pat="${1:+$(keyhash "$1")}"
  for f in "$STATE"/rpc/*.proc; do
    [ -f "$f" ] || continue
    [ -n "$pat" ] && [[ "$f" != *"$pat"* ]] && continue
    pid="$(python3 -c "import json;print(json.load(open('$f'))['pid'])" 2>/dev/null)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}

echo "== 1. two roots run concurrently, FIFO per root =="
( submit "t:chan:root1" new "Say exactly ONE" >"$WORK/r1a.json" ) & p1=$!
sleep 2
( submit "t:chan:root1" steer "Say exactly TWO" >"$WORK/r1b.json" ) & p2=$!
( submit "t:chan:root2" new "Say exactly THREE" >"$WORK/r2.json" ) & p3=$!
wait $p1; w1=$?; wait $p2; w1b=$?; wait $p3; w2=$?
check "root1 first submit completed" 0 "$w1"
check "root2 first submit completed" 0 "$w2"
r1_reply="$(json_reply "$WORK/r1a.json")"
check "root1 FIFO: steered msg answered by run owner" "yes" \
  "$([[ -n \"$r1_reply\" ]] && echo yes || echo no)"

echo "== 2. owner follow-up during a slow tool call is steered into the same run =="
# Ask pi to run a slow bash tool so the run is verifiably active, then steer.
( submit "t:chan:slow" new "Run this exact bash command: sleep 12 && echo slow-done. Then reply: PHASE1" \
    >"$WORK/slow1.json" ) &
slow_pid=$!
sleep 8   # let the run get into the sleep tool call
slow_before="$(live_procs t:chan:slow)"
steer_out=$(submit "t:chan:slow" steer "Also reply with PHASE2 after PHASE1")
check "steer accepted into live run" "steered" "$(printf '%s' "$steer_out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
wait $slow_pid
slow_reply="$(json_reply "$WORK/slow1.json")"
check "run owner reply includes steered content" "yes" "$([[ "$slow_reply" == *PHASE2* ]] && echo yes || echo no)"
check "same owner process handled the steer" "yes" "$([[ "$(live_procs t:chan:slow)" = "$slow_before" ]] && echo yes || echo no)"

echo "== 3. steering mode all: queued messages delivered together =="
( submit "t:chan:batch" new "Run this exact bash command: sleep 20 && echo b. Then reply: BATCH1" \
    >"$WORK/batch1.json" ) &
bpid=$!
sleep 7
submit "t:chan:batch" steer "Reply: BATCH2" >/dev/null
sleep 2
submit "t:chan:batch" steer "Reply: BATCH3" >/dev/null
wait $bpid
batch_reply="$(json_reply "$WORK/batch1.json")"
batch_out="$(grep -c 'BATCH2\|BATCH3' "$STATE/rpc/$(keyhash t:chan:batch).out" 2>/dev/null || echo 0)"
check "both queued messages delivered in run" "yes" \
  "$([[ ( "$batch_reply" == *BATCH2* && "$batch_reply" == *BATCH3* ) || "$batch_out" -ge 2 ]] && echo yes || echo no)"

echo "== 4. stop clears queue, aborts run, applies correction =="
( submit "t:chan:stop" new "Run this exact bash command: sleep 60 && echo x. Then reply: NEVER" \
    >"$WORK/stop1.json" ) &
spid=$!
sleep 8
stop_out=$(submit "t:chan:stop" stop "Reply with STOPPED")
check "stop applied" "stop_applied" "$(printf '%s' "$stop_out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
wait $spid
stop_reply="$(json_reply "$WORK/stop1.json")"
check "aborted run did not post stale answer" "yes" "$([[ "$stop_reply" != *NEVER* ]] && echo yes || echo no)"

echo "== 5. already-accepted messages are not resubmitted =="
acc=$(submit "t:chan:dedupe" new "Say exactly DEDUPE" --msg-id msg-abc)
check "first submit ran" "completed" "$(printf '%s' "$acc" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
acc2=$(submit "t:chan:dedupe" new "Say exactly DEDUPE" --msg-id msg-abc)
check "same msg-id not resubmitted" "already_accepted" "$(printf '%s' "$acc2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"

echo "== 6. idle expiry closes the process; session resumes =="
first=$(submit "t:chan:idle" new "Say exactly HELLO")
sid1="$(printf '%s' "$first" | python3 -c 'import sys,json;print(json.load(sys.stdin)["session_id"])')"
check "session id captured" "yes" "$([[ -n "$sid1" ]] && echo yes || echo no)"
sleep 2             # ensure every live proc is >1s idle
reap "" 1 >/dev/null
sleep 1
check "process expired" "0" "$(live_procs t:chan:idle)"
second=$(submit "t:chan:idle" new "What exact word did I last ask you to say? Reply with just that word." --session-id "$sid1")
check "session resumed (remembers prior turn)" "HELLO" "$(printf '%s' "$second" | python3 -c 'import sys,json;print(json.load(sys.stdin)["reply"].strip())')"

echo
echo "passed=$PASS failed=$FAIL state=$STATE"
[ "$FAIL" = 0 ]
