#!/usr/bin/env python3
"""Per-thread live Pi RPC owner manager for the buzz watcher.

A per-agent daemon holds one long-lived `pi --mode rpc` process per
(agent, channel, root) thread. The shell watcher keeps discovery, filtering,
reactions, and posting; this daemon owns the live process, message routing
(steer / followUp / stop), idle expiry, LRU capping, and per-message delivery
state:

    discovered -> accepted_by_pi -> included_in_run -> completed

On owner restart, submit reconciles the inbox: messages never accepted by Pi
are redelivered, already-accepted ones are skipped (they are already in the
Pi session on disk).

Layout under --state-dir:
  rpc-owner.sock                  daemon control socket (one JSONL req/resp)
  owners/<agent>/<channel>/<root>/
    inbox/<msg_id>.json           per-message delivery state
    runs/<run_id>.json            one record per settled run
    owner.json                    live pid + session id (removed on exit)
    log                           owner diagnostics (never protocol data)

CLI:
  daemon  --state-dir D [--idle-expire S] [--max-owners N] ...
  submit  --state-dir D --agent A --channel C --root R --msg-id ID
          --text T --routing steer|followup|stop|new [--session-id SID]
          [--work-dir D] [--timeout S]
          -> {"ok":true,"started":bool,"run_id":...}
  wait    --state-dir D --agent A --channel C --root R [--run-id ID]
          [--timeout S]
          -> settled run JSON {"text":..., "aborted":..., "session_id":...}
  pending --state-dir D --agent A --channel C --root R
  stop-owner --state-dir D --agent A --channel C --root R   # /fresh, recycle
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid

DEFAULT_PROVIDER = os.environ.get("PI_RPC_PROVIDER", "ppq")
DEFAULT_MODEL = os.environ.get("PI_RPC_MODEL")
DEFAULT_IDLE_EXPIRE = int(os.environ.get("PI_RPC_IDLE_EXPIRE", "1800"))
MAX_OWNERS = int(os.environ.get("PI_RPC_MAX_OWNERS", "8"))


def owner_dir(state_dir, agent, channel, root):
    return os.path.join(state_dir, "owners", agent, channel, root)


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def read_json(path):
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Owner: one live pi RPC process
# ---------------------------------------------------------------------------

class Owner:
    def __init__(self, daemon, odir, session_id, work_dir, provider, model, log):
        self.daemon = daemon
        self.odir = odir
        self.inbox = os.path.join(odir, "inbox")
        self.lock = threading.RLock()
        self.active = False
        self.last_activity = time.time()
        self.pending_ids = []        # msg ids in the current run
        self.run_id = None
        self.responses = {}
        self.settled_runs = {}       # run_id -> record
        self.shutting_down = False
        self.session_id = session_id
        self.log = log

        cmd = ["pi", "--mode", "rpc", "--provider", provider]
        if model:
            cmd += ["--model", model]
        cmd += ["--session-dir", odir]
        if session_id:
            cmd += ["--session-id", session_id]
        cwd = work_dir if work_dir and os.path.isdir(work_dir) else os.getcwd()
        log.write("spawn: %s (cwd=%s)\n" % (" ".join(cmd), cwd))
        log.flush()
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, cwd=cwd, bufsize=0)
        threading.Thread(target=self._reader, daemon=True).start()
        # Batch rapid owner follow-ups: all queued steering messages are
        # delivered together at the next steering boundary.
        self.cmd({"type": "set_steering_mode", "mode": "all"})
        state = self.cmd({"type": "get_state"})
        if state and state.get("success"):
            self.session_id = (state.get("data") or {}).get("sessionId") or session_id
        threading.Thread(target=self._idler, daemon=True).start()
        write_json(os.path.join(odir, "owner.json"),
                   {"pid": self.proc.pid, "session_id": self.session_id,
                    "started": time.time(), "model": model})

    # -- protocol ----------------------------------------------------------
    def cmd(self, rec, timeout=60):
        cid = uuid.uuid4().hex[:12]
        rec = dict(rec, id=cid)
        try:
            self.proc.stdin.write((json.dumps(rec) + "\n").encode())
            self.proc.stdin.flush()
        except Exception as e:
            self.log.write("stdin write failed: %s\n" % e)
            return {"success": False, "error": str(e)}
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp = self.responses.get(cid)
            if resp is not None:
                return resp
            time.sleep(0.01)
        return {"success": False, "error": "timeout"}

    def _reader(self):
        current_text = []
        current_usage = []
        for raw in self.proc.stdout:
            self.last_activity = time.time()
            try:
                rec = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                self.log.write("unparseable: %r\n" % raw[:200])
                continue
            rtype = rec.get("type")
            if rtype == "response" and rec.get("id"):
                self.responses[rec["id"]] = rec
            elif rtype == "agent_start":
                with self.lock:
                    if not self.active:
                        self.active = True
                        self.run_id = uuid.uuid4().hex[:12]
                        self.pending_ids = []
                        current_text = []
                        current_usage = []
            elif rtype == "message_update":
                evd = rec.get("assistantMessageEvent") or {}
                if evd.get("type") == "text_delta":
                    current_text.append(evd.get("delta", ""))
            elif rtype == "turn_end":
                # Real cost accounting: pi json-mode cost extraction reads
                # turn_end usage; accumulate the same here per run.
                msg = rec.get("message") or {}
                usage = msg.get("usage") or {}
                if usage:
                    current_usage.append({
                        "model": msg.get("model", ""),
                        "usage": usage,
                    })
            elif rtype == "agent_settled":
                # Wait for agent_settled, not agent_end: retries, compaction,
                # and steering can follow agent_end.
                with self.lock:
                    run_id, pids, usage = self.run_id, list(self.pending_ids), list(current_usage)
                    self.active = False
                    self.run_id = None
                    self.pending_ids = []
                self.last_activity = time.time()
                sid = self.session_id
                if not sid:
                    state = self.cmd({"type": "get_state"})
                    if state and state.get("success"):
                        sid = (state.get("data") or {}).get("sessionId")
                        self.session_id = sid
                record = {
                    "run": run_id, "settled": time.time(),
                    "aborted": bool(rec.get("aborted")),
                    "text": "".join(current_text),
                    "messages": pids,
                    "usage": usage,
                    "session_id": sid,
                }
                if run_id:
                    write_json(os.path.join(self.odir, "runs", run_id + ".json"), record)
                    self.settled_runs[run_id] = record
                for mid in pids:
                    self._mark(mid, "completed")
        # stdout closed: process is going away
        with self.lock:
            self.active = False
        try:
            os.remove(os.path.join(self.odir, "owner.json"))
        except OSError:
            pass
        self.log.write("owner exited rc=%s\n" % self.proc.wait())
        self.log.flush()
        self.daemon.forget(self)

    def _idler(self):
        while self.proc.poll() is None and not self.shutting_down:
            time.sleep(5)
            with self.lock:
                if self.active:
                    # An active run is activity; expiry never extends a hung
                    # run beyond the watcher's own turn timeout, which aborts
                    # via stop-owner/abort.
                    self.last_activity = time.time()
                    continue
                idle = time.time() - self.last_activity
            if idle > self.daemon.idle_expire:
                self.log.write("idle expiry after %ss\n" % int(idle))
                break
        self.shutdown()

    def shutdown(self):
        self.shutting_down = True
        if self.proc.poll() is None:
            try:
                self.proc.stdin.close()
            except Exception:
                pass
            try:
                self.proc.wait(timeout=10)
            except Exception:
                self.proc.kill()

    # -- delivery ----------------------------------------------------------
    def _mark(self, msg_id, state):
        path = os.path.join(self.inbox, msg_id + ".json")
        try:
            rec = read_json(path)
        except Exception:
            return
        rec["state"] = state
        if state == "accepted_by_pi":
            rec["accepted_at"] = time.time()
        write_json(path, rec)

    def deliver(self, msg_id, text, routing):
        """Route one message into the live process. Returns (ok, error)."""
        rec = {"type": "prompt", "message": text}
        with self.lock:
            running = self.active
        if routing == "stop":
            # Do not rely on steering to interrupt an executing tool:
            # empty the queue, abort, then submit the correction fresh.
            self.cmd({"type": "clear_queue"})
            self.cmd({"type": "abort"})
            running = False
        if running:
            if routing == "new":
                routing = "steer"  # owner follow-up during a run steers
            rec["streamingBehavior"] = "steer" if routing == "steer" else "followUp"
        resp = self.cmd(rec)
        if not resp.get("success"):
            return False, resp.get("error", "prompt rejected")
        self._mark(msg_id, "accepted_by_pi")
        disp = (resp.get("data") or {}).get("disposition")
        if disp in ("started", "queued"):
            self._mark(msg_id, "included_in_run")
            with self.lock:
                if self.run_id:
                    self.pending_ids.append(msg_id)
        return True, None

    def pending_count(self):
        n = 0
        if os.path.isdir(self.inbox):
            for f in os.listdir(self.inbox):
                try:
                    if read_json(os.path.join(self.inbox, f)).get("state") != "completed":
                        n += 1
                except Exception:
                    pass
        return n


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self, state_dir, idle_expire, max_owners, provider, model):
        self.state_dir = state_dir
        self.idle_expire = idle_expire
        self.max_owners = max_owners
        self.provider = provider
        self.model = model
        self.owners = {}   # odir -> Owner
        self.lock = threading.Lock()
        self.sock_path = os.path.join(state_dir, "rpc-owner.sock")

    def log(self, msg):
        sys.stderr.write("[rpc-owner-daemon] %s\n" % msg)
        sys.stderr.flush()

    def forget(self, owner):
        with self.lock:
            self.owners.pop(owner.odir, None)

    def live_meta(self, odir):
        """Liveness check for owners from a previous daemon run."""
        path = os.path.join(odir, "owner.json")
        try:
            meta = read_json(path)
            os.kill(meta["pid"], 0)
            return meta
        except Exception:
            return None

    def reap_stale(self, odir):
        meta = self.live_meta(odir)
        if meta:
            try:
                os.kill(meta["pid"], 15)
                self.log("killed stale owner pid %s in %s" % (meta["pid"], odir))
            except OSError:
                pass
        try:
            os.remove(os.path.join(odir, "owner.json"))
        except OSError:
            pass

    def get_owner(self, odir, session_id, work_dir):
        with self.lock:
            owner = self.owners.get(odir)
            if owner and owner.proc.poll() is None:
                return owner, False
            self.reap_stale(odir)
            os.makedirs(os.path.join(odir, "inbox"), exist_ok=True)
            os.makedirs(os.path.join(odir, "runs"), exist_ok=True)
            # Cap live processes per agent: reap LRU idle owners first.
            self.reap_lru()
            owner = Owner(self, odir, session_id, work_dir, self.provider, self.model,
                          open(os.path.join(odir, "log"), "a"))
            self.owners[odir] = owner
            return owner, True

    def reap_lru(self):
        if len(self.owners) < self.max_owners:
            return
        candidates = sorted((o.last_activity, od, o) for od, o in self.owners.items())
        for _, od, o in candidates:
            if len(self.owners) <= self.max_owners:
                break
            with o.lock:
                idle = not o.active
            if idle:
                self.log("LRU reap: %s" % od)
                o.shutdown()
                self.forget(o)

    # -- request handlers ----------------------------------------------------
    def handle(self, req):
        action = req.get("action")
        odir = owner_dir(self.state_dir, req["agent"], req["channel"], req["root"])
        if action == "submit":
            return self.h_submit(odir, req)
        if action == "wait":
            return self.h_wait(odir, req)
        if action == "pending":
            owner = self.owners.get(odir)
            meta = self.live_meta(odir)
            return {"live": bool(owner or meta),
                    "pending": owner.pending_count() if owner else None}
        if action == "stop-owner":
            owner = self.owners.get(odir)
            if owner:
                owner.shutdown()
                self.forget(owner)
            else:
                self.reap_stale(odir)
            return {"ok": True}
        return {"ok": False, "error": "unknown action %r" % action}

    def h_submit(self, odir, req):
        os.makedirs(os.path.join(odir, "inbox"), exist_ok=True)
        msg_path = os.path.join(odir, "inbox", req["msg_id"] + ".json")
        write_json(msg_path, {"msg_id": req["msg_id"], "text": req["text"],
                              "routing": req["routing"], "state": "discovered",
                              "queued_at": time.time()})
        # Redeliver older never-accepted messages ahead of this one (restart
        # reconciliation; already-accepted ones live in the Pi session).
        backlog = []
        for f in sorted(os.listdir(os.path.join(odir, "inbox"))):
            if f == req["msg_id"] + ".json":
                continue
            try:
                rec = read_json(os.path.join(odir, "inbox", f))
            except Exception:
                continue
            if rec.get("state") == "discovered":
                backlog.append(rec)
        owner, started = self.get_owner(odir, req.get("session_id"), req.get("work_dir"))
        for rec in backlog:
            owner.deliver(rec["msg_id"], rec["text"], rec.get("routing") or "new")
        ok, err = owner.deliver(req["msg_id"], req["text"], req["routing"])
        if not ok:
            # Leave state at discovered so a later submit retries it.
            write_json(msg_path, {"msg_id": req["msg_id"], "text": req["text"],
                                  "routing": req["routing"], "state": "discovered",
                                  "error": err, "queued_at": time.time()})
            return {"ok": False, "error": err}
        with owner.lock:
            run_id = owner.run_id
        return {"ok": True, "started": started, "run_id": run_id,
                "session_id": owner.session_id}

    def h_wait(self, odir, req):
        run_id = req.get("run_id")
        timeout = req.get("timeout", 600)
        deadline = time.time() + timeout
        # Wait until the thread's queue has drained: no active run and no
        # pending (incomplete) messages. Rapid steering and follow-ups then
        # produce ONE coherent answer, not a stale early one.
        while time.time() < deadline:
            owner = self.owners.get(odir)
            runs_dir = os.path.join(odir, "runs")
            candidates = []
            if owner:
                candidates = list(owner.settled_runs.values())
            elif os.path.isdir(runs_dir):
                for f in os.listdir(runs_dir):
                    if f.endswith(".json"):
                        try:
                            candidates.append(read_json(os.path.join(runs_dir, f)))
                        except Exception:
                            pass
            drained = True
            if owner:
                with owner.lock:
                    drained = not owner.active
                if drained and owner.pending_count() > 0:
                    drained = False
            elif self.live_meta(odir):
                drained = False  # a previous daemon's owner may still be mid-run
            if run_id:
                match = [r for r in candidates if r.get("run") == run_id]
            else:
                match = [r for r in candidates
                         if time.time() - r.get("settled", 0) < timeout]
            if match and drained:
                rec = dict(match[-1])
                owner = self.owners.get(odir)
                if owner:
                    rec["session_id"] = owner.session_id
                    rec["pending"] = owner.pending_count()
                else:
                    try:
                        rec["session_id"] = read_json(
                            os.path.join(odir, "owner.json")).get("session_id")
                    except Exception:
                        pass
                return {"ok": True, "run": rec}
            time.sleep(0.3)
        return {"ok": False, "error": "timeout waiting for run to settle"}

    # -- socket loop ---------------------------------------------------------
    def serve(self):
        os.makedirs(self.state_dir, exist_ok=True)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.remove(self.sock_path)
        except OSError:
            pass
        sock.bind(self.sock_path)
        sock.listen(32)
        self.log("listening on %s" % self.sock_path)
        while True:
            conn, _ = sock.accept()
            threading.Thread(target=self.conn_loop, args=(conn,), daemon=True).start()

    def conn_loop(self, conn):
        f = conn.makefile("rb")
        try:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    req = json.loads(line.decode())
                except Exception:
                    self._reply(conn, {"ok": False, "error": "bad request"})
                    continue
                resp = self.handle(req)
                self._reply(conn, resp)
                if req.get("action") == "wait":
                    break  # one request per connection; wait returns once
        finally:
            conn.close()

    @staticmethod
    def _reply(conn, obj):
        conn.sendall((json.dumps(obj) + "\n").encode())


def spawn_daemon(state_dir):
    """Start the daemon detached if its socket is not serving."""
    sock_path = os.path.join(state_dir, "rpc-owner.sock")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(sock_path)
        probe.close()
        return  # already running
    except OSError:
        pass
    subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "daemon", "--state-dir", state_dir],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True)
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.connect(sock_path)
            probe.close()
            return
        except OSError:
            time.sleep(0.1)
    sys.stderr.write("daemon failed to start\n")
    sys.exit(1)


def request(state_dir, req):
    spawn_daemon(state_dir)
    sock_path = os.path.join(state_dir, "rpc-owner.sock")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(req.get("timeout", 600) + 30)
    sock.connect(sock_path)
    sock.sendall((json.dumps(req) + "\n").encode())
    f = sock.makefile("rb")
    line = f.readline()
    sock.close()
    if not line:
        print(json.dumps({"ok": False, "error": "daemon closed connection"}))
        return 1
    print(line.decode())
    return 0 if json.loads(line).get("ok", False) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--state-dir", required=True)
        p.add_argument("--agent", required=True)
        p.add_argument("--channel", required=True)
        p.add_argument("--root", required=True)

    p = sub.add_parser("daemon")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--idle-expire", type=int, default=DEFAULT_IDLE_EXPIRE)
    p.add_argument("--max-owners", type=int, default=MAX_OWNERS)
    p.add_argument("--provider", default=DEFAULT_PROVIDER)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.set_defaults(func=lambda a: Daemon(a.state_dir, a.idle_expire, a.max_owners,
                                         a.provider, a.model).serve())

    p = sub.add_parser("submit")
    common(p)
    p.add_argument("--msg-id", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--routing", choices=["steer", "followup", "stop", "new"], default="new")
    p.add_argument("--session-id", default=None)
    p.add_argument("--work-dir", default=None)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=lambda a: request(a.state_dir, {
        "action": "submit", "agent": a.agent, "channel": a.channel, "root": a.root,
        "msg_id": a.msg_id, "text": a.text, "routing": a.routing,
        "session_id": a.session_id, "work_dir": a.work_dir, "timeout": a.timeout}))

    p = sub.add_parser("wait")
    common(p)
    p.add_argument("--run-id", default=None)
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=lambda a: request(a.state_dir, {
        "action": "wait", "agent": a.agent, "channel": a.channel, "root": a.root,
        "run_id": a.run_id, "timeout": a.timeout}))

    p = sub.add_parser("pending")
    common(p)
    p.add_argument("--timeout", type=int, default=30)
    p.set_defaults(func=lambda a: request(a.state_dir, {
        "action": "pending", "agent": a.agent, "channel": a.channel, "root": a.root,
        "timeout": a.timeout}))

    p = sub.add_parser("stop-owner")
    common(p)
    p.add_argument("--timeout", type=int, default=30)
    p.set_defaults(func=lambda a: request(a.state_dir, {
        "action": "stop-owner", "agent": a.agent, "channel": a.channel, "root": a.root,
        "timeout": a.timeout}))

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
