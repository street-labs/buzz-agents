#!/usr/bin/env python3
"""Live Pi RPC session manager for buzz agents.

Implements the STEERING.md design: one live `pi --mode rpc` process owns a
thread root at a time. Owner follow-ups enter the active run as steering
messages (streamingBehavior=steer), peer traffic queues as followUp, explicit
stop clears the queue and aborts, and idle processes expire while the on-disk
session stays resumable.

The shell watcher (agent-watcher.sh) stays responsible for discovery,
filtering, reactions, worktrees, and posting; it delegates active-thread
delivery here.

Process/state layout under --state-dir (files keyed by a hash of
"<agent>:<channel_id>:<root_id>"):
    <state>/rpc/<h>.proc         live process record (pid, sid, model, times)
    <state>/rpc/<h>.fifo         RPC command stdin (named pipe; a holder keeps
                                 the write end open so writers never EOF it)
    <state>/rpc/<h>.out          pi stdout: strict JSONL events + responses
    <state>/rpc/<h>.msgs/<id>.state  per-message delivery state:
        discovered -> accepted_by_pi -> included_in_run -> completed

CLI:
  submit --key K --message M --intent steer|followup|stop|new [--model M]
         [--session-id S] [--workdir D] [--system-prompt-file F]
         [--run-timeout SEC] [--msg-id ID]
    -> prints one JSON line:
       {"status": "completed"|"timeout"|"steered"|"queued"|"stop_applied"
                  |"already_accepted"|"error",
        "reply": str, "session_id": str, "cost": "usd:tokens", "error": str}
    "completed"/"timeout" are terminal: the submit waited for agent_settled
    with an empty queue. "steered"/"queued" were delivered into a live run
    owned by another submit, which will return the final result.

  reap --max-idle SEC --max-live N
    -> expire idle processes (process only; session stays on disk) and enforce
       the per-agent live-process cap LRU. Prints one JSON summary line.
"""

import argparse
import fcntl
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

DEFAULT_RUN_TIMEOUT = 1800      # active-turn timeout (watcher keeps its own too)
DEFAULT_MAX_LIVE = 8            # live processes per agent (matches MAX_WORKERS)
DEFAULT_MAX_IDLE = 1800         # 30 minutes idle expiry
MAX_QUEUE = 8                   # bound on queued steering/followUp messages

# PPQ per-million-token rates by model id (input, output, cacheRead). Mirrors
# the table in harness-adapters.sh - keep both in sync. pi's own cost math is
# broken for PPQ, so cost is computed here from token counts.
RATES = {
    'z-ai/glm-5.2':              (1.586, 4.9165, 0.1506),
    'z-ai/glm-5.3':              (1.477, 4.642, 0.1477),
    'z-ai/glm-5.3-flash':        (0.15825, 0.5275, 0.03165),
    'deepseek/deepseek-v4-pro':  (0.458925, 0.91785, 0),
    'deepseek/deepseek-v4-flash':(0.10339, 0.20678, 0),
    'deepseek/deepseek-v4-flash-0731':(0.10339, 0.20678, 0),
    'qwen/qwen3-coder-flash':    (0.205725, 1.028625, 0),
    'claude-sonnet-4.6':         (3.165, 15.825, 0.3165),
    'claude-opus-4.8':           (5.275, 26.375, 0.5275),
    'claude-haiku-4.5':          (1.055, 5.275, 0.1055),
    'moonshotai/kimi-k2.6':      (1.00225, 4.22, 0),
    'moonshotai/kimi-k3':        (3.165, 15.825, 0.3165),
}
DEFAULT_RATE = (0, 0, 0)


def emit(**kw):
    out = {"status": "error", "reply": "", "session_id": "", "cost": "0.0:0", "error": ""}
    out.update(kw)
    print(json.dumps(out))
    sys.exit(0 if out["status"] not in ("error",) else 1)


def key_hash(key):
    return hashlib.sha256(key.encode()).hexdigest()[:24]


def ppaths(state_dir, key):
    d = os.path.join(state_dir, "rpc")
    h = key_hash(key)
    return {
        "dir": d, "h": h,
        "proc": os.path.join(d, h + ".proc"),
        "fifo": os.path.join(d, h + ".fifo"),
        "out": os.path.join(d, h + ".out"),
        "msgs": os.path.join(d, h + ".msgs"),
        "stdin_lock": os.path.join(d, h + ".stdin.lock"),
    }


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def proc_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def load_live(p):
    rec = read_json(p["proc"])
    if not rec or not proc_alive(rec.get("pid", 0)):
        return None
    return rec


def rpc_write(p, command):
    """Write one JSONL command into the process stdin (fifo) under the lock."""
    for _ in range(50):
        try:
            fd = os.open(p["fifo"], os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError:
            time.sleep(0.1)  # holder between opens; retry briefly
    else:
        return False
    try:
        with open(p["stdin_lock"]) as lockf:
            fcntl.flock(lockf, fcntl.LOCK_EX)
            try:
                with os.fdopen(fd, "w") as f:
                    f.write(json.dumps(command) + "\n")
            finally:
                fcntl.flock(lockf, fcntl.LOCK_UN)
    except (BrokenPipeError, OSError):
        return False
    return True


def spawn_holder(p):
    """Keep the fifo write end open forever so writer opens never see EOF."""
    if os.fork() == 0:
        os.setsid()
        # Detach fully: an inherited stdout/stderr would hold a caller's pipe
        # open forever (submit | tail never sees EOF).
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
        if devnull > 2:
            os.close(devnull)
        fd = os.open(p["fifo"], os.O_WRONLY)
        try:
            while True:
                time.sleep(3600)
        finally:
            os.close(fd)  # pragma: no cover
    os.waitpid(-1, os.WNOHANG)  # reap nothing; holder is orphaned to init


def request_state(p, rid=None):
    """get_state round-trip; returns the RpcSessionState data or None."""
    rid = rid or ("gs-" + str(time.time()))
    rpc_write(p, {"id": rid, "type": "get_state"})
    deadline = time.time() + 15
    with open(p["out"]) as f:
        f.seek(0, 2)
        while time.time() < deadline:
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "response" and ev.get("command") == "get_state" and ev.get("id") == rid:
                return ev.get("data") or {}
    return None


def start_process(args, state_dir, key, session_id):
    p = ppaths(state_dir, key)
    if not os.path.exists(p["fifo"]):
        os.mkfifo(p["fifo"])
    open(p["stdin_lock"], "a").close()
    # fresh event log per process generation; holder first so pi's stdin never EOFs
    spawn_holder(p)
    devnull = os.open("/dev/null", os.O_RDONLY)
    outfile = os.open(p["out"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC)

    cmd = ["pi", "--mode", "rpc"]
    if session_id:
        cmd += ["--session", session_id]
    if args.model:
        cmd += ["--model", args.model]
    if args.system_prompt_file and os.path.exists(args.system_prompt_file):
        with open(args.system_prompt_file) as f:
            sp = f.read().strip()
        if sp:
            cmd += ["--append-system-prompt", sp]
    pid = subprocess.Popen(
        cmd, cwd=args.workdir or None,
        stdin=open(p["fifo"]), stdout=outfile, stderr=devnull,
    ).pid

    rec = {
        "key": key, "pid": pid, "session_id": session_id or "",
        "model": args.model or "", "workdir": args.workdir or "",
        "started": time.time(), "last_active": time.time(), "out_offset": 0,
    }
    save_proc(p, rec)
    # Batch rapid follow-ups: every queued message is delivered at the boundary.
    rpc_write(p, {"id": "cfg-1", "type": "set_steering_mode", "mode": "all"})
    rpc_write(p, {"id": "cfg-2", "type": "set_follow_up_mode", "mode": "all"})
    # RPC mode emits no session event: discover the (possibly new) session id
    # from get_state so the watcher can persist it for restart resumption.
    st = request_state(p, "cfg-3")
    if st:
        rec["session_id"] = st.get("sessionId") or rec["session_id"]
        save_proc(p, rec)
    return rec


def save_proc(p, rec):
    os.makedirs(p["dir"], exist_ok=True)
    with open(p["proc"], "w") as f:
        json.dump(rec, f)


def touch(p, rec):
    rec["last_active"] = time.time()
    save_proc(p, rec)


def msg_state_path(p, msg_id):
    return os.path.join(p["msgs"], re.sub(r"[^A-Za-z0-9_-]", "_", msg_id) + ".state")


def set_msg_state(p, msg_id, state):
    os.makedirs(p["msgs"], exist_ok=True)
    with open(msg_state_path(p, msg_id), "w") as f:
        json.dump({"state": state, "at": time.time()}, f)


def get_msg_state(p, msg_id):
    return ((read_json(msg_state_path(p, msg_id)) or {}).get("state", ""))


def tail_events(p, rec, run_timeout, settle_seconds=0.0):
    """Tail the event log until the agent settles with an empty queue.

    Waits for agent_settled (never agent_end: steering, retries, or compaction
    can follow agent_end). Returns (reply, sid, cost_str, status).
    """
    reply = ""
    sid = rec.get("session_id") or ""
    total_cost = 0.0
    total_tokens = 0
    deadline = time.time() + run_timeout

    off = rec.get("out_offset", 0)
    f = open(p["out"])
    f.seek(off)
    quiet_since = None
    status = "timeout"

    while time.time() < deadline:
        line = f.readline()
        if not line:
            if quiet_since is not None and time.time() - quiet_since >= settle_seconds:
                status = "completed"
                break
            time.sleep(0.2)
            continue
        quiet_since = None
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "session":
            sid = ev.get("id") or sid
        elif t == "message_update":
            ame = ev.get("assistantMessageEvent") or {}
            if ame.get("type") == "text_end" and isinstance(ame.get("content"), str):
                reply = ame["content"]
            msg = ev.get("message") or {}
            if msg.get("role") == "assistant":
                for c in msg.get("content") or []:
                    if c.get("type") == "text" and c.get("text"):
                        reply = c["text"]
        elif t == "message_end":
            msg = ev.get("message") or {}
            if msg.get("role") == "assistant":
                for c in msg.get("content") or []:
                    if c.get("type") == "text" and c.get("text"):
                        reply = c["text"]
        elif t == "turn_end":
            msg = ev.get("message") or {}
            usage = msg.get("usage") or {}
            model_id = msg.get("model", "") or rec.get("model", "")
            inp, outp, cache_r = RATES.get(model_id, DEFAULT_RATE)
            t_in = usage.get("input", 0) or 0
            t_out = usage.get("output", 0) or 0
            t_cr = usage.get("cacheRead", 0) or 0
            total_cost += (inp * t_in + outp * t_out + cache_r * t_cr) / 1_000_000
            total_tokens += usage.get("totalTokens", 0) or 0
            if model_id and model_id not in RATES:
                print(f"WARNING: no PPQ rate for model {model_id!r} in pi_rpc_owner.py RATES; cost tracked as 0",
                      file=sys.stderr)
        elif t == "agent_settled":
            # Settle window: coalesce a steering message that lands right behind
            # the settled event (rapid human follow-ups), then confirm the queue
            # drained before treating the run as final.
            quiet_since = time.time()
            if settle_seconds <= 0:
                status = "completed"
                break

    rec["out_offset"] = f.tell()
    rec["session_id"] = sid
    touch(p, rec)
    return reply, sid, f"{total_cost:.6f}:{total_tokens}", status


def queue_depth(p):
    st = request_state(p)
    if st is None:
        return 0, False
    return st.get("pendingMessageCount") or 0, bool(st.get("isStreaming"))


def do_stop(p, rec):
    """clear_queue then abort, per spec. Never steer into an executing tool."""
    rpc_write(p, {"id": "sq-1", "type": "clear_queue"})
    rpc_write(p, {"id": "ab-1", "type": "abort"})
    touch(p, rec)


def cmd_submit(args):
    if not args.message and args.intent != "stop":
        emit(error="submit requires --message")
    p = ppaths(args.state_dir, args.key)
    os.makedirs(p["dir"], exist_ok=True)

    # Restart safety: a message already accepted by pi must not be resubmitted.
    if args.msg_id and get_msg_state(p, args.msg_id) in ("accepted_by_pi", "included_in_run", "completed"):
        emit(status="already_accepted")

    rec = load_live(p)
    if rec:
        # Session mismatch means the thread's session was reset underneath the
        # live owner (/fresh, carry-over reseed): the old process points at a
        # dead session, so stop it and start fresh on the current session id.
        old_sid = rec.get("session_id") or ""
        if old_sid and args.session_id and old_sid != args.session_id:
            try:
                os.kill(rec["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                os.remove(p["proc"])
            except OSError:
                pass
            rec = None

    if args.intent == "stop":
        if not rec:
            emit(status="stop_applied", session_id=(read_json(p["proc"]) or {}).get("session_id", ""))
        do_stop(p, rec)
        if args.message:  # correction after abort goes in as a fresh prompt
            rpc_write(p, {"id": "p-stop", "type": "prompt", "message": args.message})
            if args.msg_id:
                set_msg_state(p, args.msg_id, "included_in_run")
            reply, sid, cost, status = tail_events(p, rec, args.run_timeout)
            emit(status="stop_applied", reply=reply, session_id=sid, cost=cost,
                 run_status=status)
        emit(status="stop_applied", session_id=rec.get("session_id", ""))

    if rec:
        depth, streaming = queue_depth(p)
        if depth >= MAX_QUEUE:
            emit(error=f"queue full ({depth} pending) for {args.key}")
        if streaming and args.intent == "steer":
            if args.msg_id:
                set_msg_state(p, args.msg_id, "accepted_by_pi")
            if rpc_write(p, {"id": "steer-" + str(time.time()), "type": "steer", "message": args.message}):
                if args.msg_id:
                    set_msg_state(p, args.msg_id, "included_in_run")
                touch(p, rec)
                emit(status="steered", session_id=rec.get("session_id", ""))
        elif streaming and args.intent == "followup":
            if args.msg_id:
                set_msg_state(p, args.msg_id, "accepted_by_pi")
            rpc_write(p, {"id": "fu-" + str(time.time()), "type": "follow_up", "message": args.message})
            if args.msg_id:
                set_msg_state(p, args.msg_id, "included_in_run")
            touch(p, rec)
            emit(status="queued", session_id=rec.get("session_id", ""))
        else:
            # idle live session (or steer with nothing running): normal prompt
            if args.msg_id:
                set_msg_state(p, args.msg_id, "accepted_by_pi")
            rpc_write(p, {"id": "p-" + str(time.time()), "type": "prompt", "message": args.message})
            if args.msg_id:
                set_msg_state(p, args.msg_id, "included_in_run")
            reply, sid, cost, status = tail_events(p, rec, args.run_timeout, settle_seconds=args.settle)
            emit(status=status, reply=reply, session_id=sid, cost=cost)

    # No live process: start one resuming the on-disk session (if any).
    rec = start_process(args, args.state_dir, args.key, args.session_id or "")
    if args.msg_id:
        set_msg_state(p, args.msg_id, "accepted_by_pi")
    rpc_write(p, {"id": "p-new", "type": "prompt", "message": args.message})
    if args.msg_id:
        set_msg_state(p, args.msg_id, "included_in_run")
    reply, sid, cost, status = tail_events(p, rec, args.run_timeout, settle_seconds=args.settle)
    emit(status=status, reply=reply, session_id=sid, cost=cost)


def cmd_reap(args):
    d = os.path.join(args.state_dir, "rpc")
    expired, dead, live = [], [], []
    if not os.path.isdir(d):
        print(json.dumps({"expired": expired, "dead": dead, "live": live}))
        return
    now = time.time()
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".proc"):
            continue
        path = os.path.join(d, fn)
        rec = read_json(path)
        if not rec:
            continue
        key = rec.get("key", fn[:-5])
        if not proc_alive(rec.get("pid", 0)):
            os.remove(path)
            dead.append(key)
            continue
        if now - rec.get("last_active", now) > args.max_idle:
            try:
                os.kill(rec["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.remove(path)
            expired.append(key)
            continue
        live.append((rec.get("last_active", 0), rec, path))
    # Cap enforcement: reap LRU sessions first. A mid-run process is never
    # reaped here regardless of LRU order - the active-turn timeout owns hung
    # runs, and idle expiry owns quiet ones.
    live.sort(key=lambda x: x[0])
    while len(live) > args.max_live:
        _, rec, path = live.pop(0)
        p = ppaths(args.state_dir, rec["key"])
        depth, streaming = queue_depth(p)
        if streaming:
            continue  # active run: not idle, skip
        try:
            os.kill(rec["pid"], signal.SIGTERM)
        except ProcessLookupError:
            pass
        os.remove(path)
        expired.append(rec.get("key", ""))
    print(json.dumps({"expired": expired, "dead": dead,
                      "live": [r.get("key", "") for _, r, _ in live]}))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("submit")
    s.add_argument("--state-dir", required=True)
    s.add_argument("--key", required=True)
    s.add_argument("--message", default="")
    s.add_argument("--intent", choices=["steer", "followup", "stop", "new"], default="new")
    s.add_argument("--model", default="")
    s.add_argument("--session-id", default="")
    s.add_argument("--workdir", default="")
    s.add_argument("--system-prompt-file", default="")
    s.add_argument("--run-timeout", type=int, default=DEFAULT_RUN_TIMEOUT)
    s.add_argument("--settle", type=float, default=0.0,
                   help="seconds to stay quiet after agent_settled before finalizing (coalesces rapid follow-ups)")
    s.add_argument("--msg-id", default="")
    s.set_defaults(func=cmd_submit)

    r = sub.add_parser("reap")
    r.add_argument("--state-dir", required=True)
    r.add_argument("--max-idle", type=int, default=DEFAULT_MAX_IDLE)
    r.add_argument("--max-live", type=int, default=DEFAULT_MAX_LIVE)
    r.set_defaults(func=cmd_reap)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
