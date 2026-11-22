#!/usr/bin/env bash
# Integration tests for pi_rpc_owner.py against the real installed pi RPC binary.
# Requires a ready provider (default: ppq / PI_RPC_MODEL). Skips if unavailable.
set -u
cd "$(dirname "$0")"

PROVIDER="${PI_RPC_PROVIDER:-ppq}"
MODEL="${PI_RPC_MODEL:-moonshotai/kimi-k3.1-pro}"
STATE="$(mktemp -d /tmp/pi-rpc-owner-test.XXXXXX)"
WORK="$(mktemp -d /tmp/pi-rpc-owner-work.XXXXXX)"
export PI_RPC_PROVIDER="$PROVIDER" PI_RPC_MODEL="$MODEL"

pass=0; fail=0
note() { echo "== $*"; }
ok() { pass=$((pass+1)); echo "ok: $*"; }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }

check_provider() {
  pi auth check --provider "$PROVIDER" >/dev/null 2>&1 || { echo "SKIP: provider $PROVIDER not ready"; exit 0; }
}
check_provider

cleanup() {
  pkill -f "pi_rpc_owner.py daemon --state-dir $STATE" 2>/dev/null
  [ -n "${S5:-}" ] && pkill -f "pi_rpc_owner.py daemon --state-dir $S5" 2>/dev/null
  rm -rf "$STATE" "$WORK" "${S5:-/nonexistent}"
}
trap cleanup EXIT

AG=testagent CH=testchan ROOT=roottest
sub() { # msg_id routing text [extra args...]
  local id="$1" rt="$2" tx="$3"; shift 3
  python3 pi_rpc_owner.py submit --state-dir "$STATE" --agent "$AG" --channel "$CH" --root "$ROOT" \
    --msg-id "$id" --routing "$rt" --text "$tx" --work-dir "$WORK" "$@"
}
waitrun() { # timeout
  python3 pi_rpc_owner.py wait --state-dir "$STATE" --agent "$AG" --channel "$CH" --root "$ROOT" \
    --timeout "$1"
}
pending_now() {
  python3 pi_rpc_owner.py pending --state-dir "$STATE" --agent "$AG" --channel "$CH" --root "$ROOT"
}

# 1. No active run: a normal prompt settles and reports a session id.
note "1. basic prompt settles"
sub m1 new "Reply with exactly: HELLO-1" >/dev/null
R1="$(waitrun 120)" || bad "wait failed: $R1"
echo "$R1" | grep -q '"ok": true' && echo "$R1" | grep -q "HELLO-1" && ok "basic run settled with text" || bad "run1: $R1"
SID1="$(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["run"].get("session_id") or "")')"
[ -n "$SID1" ] && ok "session id captured" || bad "no session id: $R1"

# 2. Owner follow-up during a run is steered into the same run.
note "2. steer into active run"
sub m2 new "Count slowly from 1 to 12, one number per line starting with: 1" >/dev/null
sleep 3   # let the run start
sub m3 steer "continue the count to 12" >/dev/null || bad "steer submit failed"
R2="$(waitrun 180)" || bad "wait2 failed"
echo "$R2" | grep -q '"ok": true' && ok "steered run settled" || bad "run2: $R2"
PENDING="$(pending_now)"
echo "$PENDING" | grep -q '"pending": 0' && ok "steered message completed (pending drained)" || bad "pending: $PENDING"

# 3. Stop: clear_queue + abort, then correction.
note "3. stop clears and aborts"
sub m4 new "Count slowly from 1 to 200, one number per line." >/dev/null
sleep 3
sub m5 stop "Stop counting. Reply with exactly: STOPPED" >/dev/null || bad "stop submit failed"
R3="$(waitrun 120)" || bad "wait3 failed"
echo "$R3" | grep -q "STOPPED" && ok "stop applied correction" || bad "run3: $R3"

# 4. Rapid owner follow-ups batch (steering mode all).
note "4. steering mode all batches follow-ups"
sub m6 new "Reply with exactly: BATCH-BASE" >/dev/null
sub m7 steer "Reply with exactly: BATCH-2" >/dev/null 2>&1
sub m8 steer "Reply with exactly: BATCH-3" >/dev/null 2>&1
R4="$(waitrun 180)" || bad "wait4 failed"
P4="$(pending_now)"
echo "$P4" | grep -q '"pending": 0' && ok "all batched messages completed" || bad "pending after batch: $P4 / $R4"

# 5. Idle expiry closes the pi process; the session file survives and a new
#    submit resumes it with the same session id.
note "5. idle expiry + resume"
S5="$(mktemp -d /tmp/pi-rpc-owner-expire.XXXXXX)"
AG5=agent5 CH5=ch5 ROOT5=root5
python3 pi_rpc_owner.py daemon --state-dir "$S5" --idle-expire 8 2>/dev/null &
DAEMON5=$!
sleep 1  # let it bind before the first submit auto-spawns a second daemon
python3 pi_rpc_owner.py submit --state-dir "$S5" --agent "$AG5" --channel "$CH5" --root "$ROOT5" \
  --msg-id e1 --routing new --text "Reply with exactly: BEFORE-IDLE" --work-dir "$WORK" >/dev/null
W5="$(python3 pi_rpc_owner.py wait --state-dir "$S5" --agent "$AG5" --channel "$CH5" --root "$ROOT5" --timeout 120)"
SID5="$(echo "$W5" | python3 -c 'import sys,json;print(json.load(sys.stdin)["run"].get("session_id") or "")')"
[ -n "$SID5" ] && ok "pre-expiry run settled" || bad "pre-expiry: $W5"
sleep 20  # idle expiry (8s) closes the pi process
python3 pi_rpc_owner.py pending --state-dir "$S5" --agent "$AG5" --channel "$CH5" --root "$ROOT5" | grep -q '"live": false' \
  && ok "owner expired while idle" || bad "owner still live after idle expiry"
python3 pi_rpc_owner.py submit --state-dir "$S5" --agent "$AG5" --channel "$CH5" --root "$ROOT5" \
  --msg-id e2 --routing new --text "Reply with exactly: AFTER-RESUME" --session-id "$SID5" --work-dir "$WORK" >/dev/null
R5="$(python3 pi_rpc_owner.py wait --state-dir "$S5" --agent "$AG5" --channel "$CH5" --root "$ROOT5" --timeout 120)"
echo "$R5" | grep -q "AFTER-RESUME" && ok "resumed session after idle expiry" || bad "run5: $R5"
kill "$DAEMON5" 2>/dev/null

# 6. Isolation: a different root gets its own owner and its own session.
note "6. thread isolation"
python3 pi_rpc_owner.py submit --state-dir "$STATE" --agent "$AG" --channel "$CH" --root "other-root" \
  --msg-id o1 --routing new --text "Reply with exactly: OTHER-ROOT" --work-dir "$WORK" >/dev/null
R6="$(python3 pi_rpc_owner.py wait --state-dir "$STATE" --agent "$AG" --channel "$CH" --root "other-root" --timeout 120)"
echo "$R6" | grep -q "OTHER-ROOT" && ok "second root isolated" || bad "other root: $R6"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
