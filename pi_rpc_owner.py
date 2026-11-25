#!/usr/bin/env python3
"""Per-thread live steering owner manager for the buzz watcher.

A per-agent daemon holds one long-lived harness process per
(agent, channel, root) thread: `pi --mode rpc`, `claude -p` in stream-json
mode, or `codex app-server` (see the Owner subclasses). The shell watcher keeps discovery, filtering,
reactions, and posting; this daemon owns the live process, message routing
(steer / followUp / stop), idle expiry, LRU capping, and per-message delivery
state:

    discovered -> accepted -> included_in_run -> completed

On owner restart, submit reconciles the inbox: messages never accepted by Pi
are redelivered, already-accepted ones are skipped (they are already in the
harness session on disk).

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
          [--work-dir D] [--harness pi|claude|codex] [--model M]
          [--system-prompt P] [--timeout S]
          -> {"ok":true,"started":bool,"run_id":...}
  wait    --state-dir D --agent A --channel C --root R [--run-id ID]
          [--timeout S]
          -> settled run JSON {"text":..., "aborted":..., "session_id":...,
             "out": <harness one-shot output>, "last": <codex only>}
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
# Owner: one live harness process per thread. The base class holds delivery
# state and run bookkeeping; a subclass per harness speaks its protocol:
#   PiOwner      pi --mode rpc            prompt + streamingBehavior steer/followUp
#   ClaudeOwner  claude -p stream-json    user messages written mid-turn are
#                                         folded into the running turn
#   CodexOwner   codex app-server         turn/start, turn/steer, turn/interrupt
# Each settled run carries "out" (and for codex "last"): the harness's own
# one-shot output format, so the watcher's extract_harness_field reads it as-is.
# ---------------------------------------------------------------------------

class Owner:
    harness = None

    def __init__(self, daemon, odir, session_id, work_dir, model, system_prompt, log):
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
        self.model = model
        self.system_prompt = system_prompt or ""
        self.log = log
        self.cwd = work_dir if work_dir and os.path.isdir(work_dir) else os.getcwd()
        cmd = self.command()
        log.write("spawn: %s (cwd=%s)\n" % (" ".join(c if len(c) < 80 else c[:77] + "..." for c in cmd), self.cwd))
        log.flush()
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr_target(), cwd=self.cwd, bufsize=0)
        threading.Thread(target=self._read_loop, daemon=True).start()
        self.handshake()
        threading.Thread(target=self._idler, daemon=True).start()
        write_json(os.path.join(odir, "owner.json"),
                   {"pid": self.proc.pid, "session_id": self.session_id, "harness": self.harness,
                    "started": time.time(), "model": model})

    # -- per-harness hooks -------------------------------------------------
    def command(self):
        raise NotImplementedError

    def stderr_target(self):
        return self.log

    def handshake(self):
        pass

    def on_event(self, rec):
        raise NotImplementedError

    def send(self, text, routing, running):
        """Hand one message to the process. Returns (ok, error)."""
        raise NotImplementedError

    def abort(self):
        raise NotImplementedError

    # -- shared plumbing ---------------------------------------------------
    def write(self, rec):
        try:
            self.proc.stdin.write((json.dumps(rec) + "\n").encode())
            self.proc.stdin.flush()
            return True, None
        except Exception as e:
            self.log.write("stdin write failed: %s\n" % e)
            return False, str(e)

    def await_response(self, key, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp = self.responses.pop(key, None)
            if resp is not None:
                return resp
            if self.proc.poll() is not None:
                return None
            time.sleep(0.01)
        return None

    def begin_run(self):
        with self.lock:
            if not self.active:
                self.active = True
                self.run_id = uuid.uuid4().hex[:12]
                self.pending_ids = []
                return True
        return False

    def settle(self, aborted, text, usage, out, last=None):
        with self.lock:
            run_id, pids = self.run_id, list(self.pending_ids)
            self.active = False
            self.run_id = None
            self.pending_ids = []
        self.last_activity = time.time()
        record = {
            "run": run_id, "settled": time.time(), "harness": self.harness,
            "aborted": bool(aborted), "text": text or "", "messages": pids,
            "usage": usage, "session_id": self.session_id, "out": out,
        }
        if last is not None:
            record["last"] = last
        if run_id:
            write_json(os.path.join(self.odir, "runs", run_id + ".json"), record)
            self.settled_runs[run_id] = record
        for mid in pids:
            self._mark(mid, "completed")

    def wait_idle(self, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if not self.active:
                    return True
            time.sleep(0.05)
        return False

    def _read_loop(self):
        for raw in self.proc.stdout:
            self.last_activity = time.time()
            try:
                rec = json.loads(raw.decode("utf-8", "replace"))
            except Exception:
                self.log.write("unparseable: %r\n" % raw[:200])
                continue
            try:
                self.on_event(rec)
            except Exception as e:
                self.log.write("event handler error: %s on %r\n" % (e, raw[:200]))
            self.log.flush()
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
        if state == "accepted":
            rec["accepted_at"] = time.time()
        write_json(path, rec)

    def deliver(self, msg_id, text, routing):
        """Route one message into the live process. Returns (ok, error)."""
        if routing == "stop":
            # Do not rely on steering to interrupt an executing tool:
            # abort, let the run settle, then submit the correction fresh.
            with self.lock:
                running = self.active
            if running:
                self.abort()
                self.wait_idle()
        with self.lock:
            running = self.active
        if running and routing == "new":
            routing = "steer"  # owner follow-up during a run steers
        ok, err = self.send(text, routing, running)
        if not ok:
            return False, err
        self._mark(msg_id, "accepted")
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


class PiOwner(Owner):
    harness = "pi"

    def command(self):
        provider, model = DEFAULT_PROVIDER, self.model
        if model and "/" in model:
            provider, model = model.split("/", 1)
        cmd = ["pi", "--mode", "rpc", "--provider", provider]
        if model:
            cmd += ["--model", model]
        if self.system_prompt:
            cmd += ["--append-system-prompt", self.system_prompt]
        cmd += ["--session-dir", self.odir]
        if self.session_id:
            cmd += ["--session-id", self.session_id]
        return cmd

    def stderr_target(self):
        return subprocess.STDOUT

    def cmd(self, rec, timeout=60):
        cid = uuid.uuid4().hex[:12]
        ok, err = self.write(dict(rec, id=cid))
        if not ok:
            return {"success": False, "error": err}
        return self.await_response(cid, timeout) or {"success": False, "error": "timeout"}

    def handshake(self):
        self.text, self.usage = [], []
        # Batch rapid owner follow-ups: all queued steering messages are
        # delivered together at the next steering boundary.
        self.cmd({"type": "set_steering_mode", "mode": "all"})
        state = self.cmd({"type": "get_state"})
        if state and state.get("success"):
            self.session_id = (state.get("data") or {}).get("sessionId") or self.session_id

    def on_event(self, rec):
        rtype = rec.get("type")
        if rtype == "response" and rec.get("id"):
            self.responses[rec["id"]] = rec
        elif rtype == "agent_start":
            if self.begin_run():
                self.text, self.usage = [], []
        elif rtype == "message_update":
            evd = rec.get("assistantMessageEvent") or {}
            if evd.get("type") == "text_delta":
                self.text.append(evd.get("delta", ""))
        elif rtype == "turn_end":
            # Real cost accounting: pi json-mode cost extraction reads
            # turn_end usage; accumulate the same here per run.
            msg = rec.get("message") or {}
            if msg.get("usage"):
                self.usage.append({"model": msg.get("model", ""), "usage": msg["usage"]})
        elif rtype == "agent_settled":
            # Wait for agent_settled, not agent_end: retries, compaction,
            # and steering can follow agent_end.
            if not self.session_id:
                threading.Thread(target=self._fetch_sid, daemon=True).start()
            text, usage = "".join(self.text), list(self.usage)
            self.settle(rec.get("aborted"), text, usage, self.pi_out(text, usage))

    def _fetch_sid(self):
        state = self.cmd({"type": "get_state"})
        if state and state.get("success"):
            self.session_id = (state.get("data") or {}).get("sessionId")

    def pi_out(self, text, usage):
        # Same events pi -p --mode json emits, so extraction and PPQ cost work unchanged.
        lines = []
        if self.session_id:
            lines.append({"type": "session", "id": self.session_id})
        lines += [{"type": "turn_end", "message": u} for u in usage]
        lines.append({"type": "message_end", "message": {
            "role": "assistant", "content": [{"type": "text", "text": text or "(no reply produced)"}]}})
        return "".join(json.dumps(l) + "\n" for l in lines)

    def send(self, text, routing, running):
        rec = {"type": "prompt", "message": text}
        if running:
            rec["streamingBehavior"] = "steer" if routing == "steer" else "followUp"
        resp = self.cmd(rec)
        if not resp.get("success"):
            return False, resp.get("error", "prompt rejected")
        return True, None

    def abort(self):
        self.cmd({"type": "clear_queue"})
        self.cmd({"type": "abort"})


class ClaudeOwner(Owner):
    """claude -p in stream-json mode. A user message written while a turn runs
    is picked up at the next tool boundary and answered in the same result
    (verified on 2.1.328), so steer and followUp are the same write."""
    harness = "claude"

    def command(self):
        cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
               "--verbose", "--permission-mode", "bypassPermissions"]
        if self.model:
            cmd += ["--model", self.model]
        if self.system_prompt:
            cmd += ["--append-system-prompt", self.system_prompt]
        if os.environ.get("AGENT_AUTOCOMPACT"):
            cmd += ["--autocompact", os.environ["AGENT_AUTOCOMPACT"]]
        if os.environ.get("AGENT_EFFORT"):
            cmd += ["--effort", os.environ["AGENT_EFFORT"]]
        if self.session_id:
            cmd += ["--resume", self.session_id]
        return cmd

    def on_event(self, rec):
        rtype = rec.get("type")
        if rec.get("session_id"):
            self.session_id = rec["session_id"]
        if rtype == "control_response":
            rid = (rec.get("response") or {}).get("request_id")
            if rid:
                self.responses[rid] = rec
        elif rtype == "result":
            # ponytail: a message that lands just after Claude decides to end its
            # turn gets a second result; we start a fresh run for it rather than
            # tracking which result answered which message.
            self.begin_run()
            self.settle(rec.get("subtype") not in (None, "success"), rec.get("result", ""),
                        rec.get("usage") or {}, json.dumps(rec))

    def send(self, text, routing, running):
        if not running:
            self.begin_run()
        return self.write({"type": "user", "message": {"role": "user", "content": text}})

    def abort(self):
        rid = uuid.uuid4().hex[:12]
        self.write({"type": "control_request", "request_id": rid, "request": {"subtype": "interrupt"}})
        self.await_response(rid, 10)


class CodexOwner(Owner):
    """codex app-server (JSON-RPC over stdio). turn/steer adds input to the
    active turn; turn/interrupt stops it; thread/resume reopens a session."""
    harness = "codex"

    def command(self):
        return ["codex", "app-server"]

    def stderr_target(self):
        return subprocess.DEVNULL

    def rpc(self, method, params, timeout=60):
        self.next_id = getattr(self, "next_id", 0) + 1
        rid = self.next_id
        ok, err = self.write({"id": rid, "method": method, "params": params})
        if not ok:
            return {"error": {"message": err}}
        return self.await_response(rid, timeout) or {"error": {"message": "timeout"}}

    def handshake(self):
        self.turn_id, self.last_text, self.usage = None, "", {}
        r = self.rpc("initialize", {"clientInfo": {"name": "buzz-agents", "version": "1"}})
        if "error" in r:
            raise RuntimeError("codex initialize: %s" % r["error"])
        self.write({"method": "initialized"})
        params = {"cwd": self.cwd, "approvalPolicy": "never", "sandbox": "danger-full-access",
                  "developerInstructions": self.system_prompt or None, "model": self.model or None}
        if os.environ.get("AGENT_EFFORT"):
            params["config"] = {"model_reasoning_effort": os.environ["AGENT_EFFORT"]}
        r = None
        if self.session_id:
            r = self.rpc("thread/resume", dict(params, threadId=self.session_id, excludeTurns=True))
            if "error" in r:
                self.log.write("thread/resume failed, starting fresh: %s\n" % r["error"])
                r = None
        if r is None:
            r = self.rpc("thread/start", params)
        if "error" in r:
            raise RuntimeError("codex thread start: %s" % r["error"])
        self.session_id = r["result"]["thread"]["id"]

    def on_event(self, rec):
        if "id" in rec and ("result" in rec or "error" in rec):
            self.responses[rec["id"]] = rec
            return
        method, p = rec.get("method"), rec.get("params") or {}
        if "id" in rec:
            # approvalPolicy=never should mean no server requests; decline anything
            # that still arrives rather than leave the turn hanging on it.
            self.log.write("declining server request %s\n" % method)
            self.write({"id": rec["id"], "error": {"code": -32601, "message": "not supported"}})
        elif method == "turn/started":
            self.turn_id = p["turn"]["id"]
        elif method == "item/completed":
            item = p.get("item") or {}
            if item.get("type") == "agentMessage":
                self.last_text = item.get("text", "")
        elif method == "thread/tokenUsage/updated":
            self.usage = (p.get("tokenUsage") or {}).get("last") or {}
        elif method == "turn/completed":
            status = (p.get("turn") or {}).get("status")
            text, u = self.last_text, self.usage
            self.turn_id, self.last_text, self.usage = None, "", {}
            usage = {"input_tokens": u.get("inputTokens", 0), "output_tokens": u.get("outputTokens", 0),
                     "reasoning_output_tokens": u.get("reasoningOutputTokens", 0)}
            # Same events codex exec --json emits, plus the -o last-message text.
            out = "".join(json.dumps(l) + "\n" for l in (
                {"type": "thread.started", "thread_id": self.session_id},
                {"type": "item.completed", "item": {"type": "agent_message", "text": text}},
                {"type": "turn.completed", "usage": usage}))
            self.settle(status != "completed", text, usage, out, last=text)

    def send(self, text, routing, running):
        inp = [{"type": "text", "text": text}]
        if running and self.turn_id:
            r = self.rpc("turn/steer", {"threadId": self.session_id, "expectedTurnId": self.turn_id,
                                        "input": inp})
            if "error" not in r:
                return True, None
            # The turn ended between our check and the steer: start a new one.
            self.log.write("turn/steer failed (%s), starting a turn\n" % r["error"].get("message"))
            self.wait_idle()
        self.begin_run()
        r = self.rpc("turn/start", {"threadId": self.session_id, "input": inp})
        if "error" in r:
            with self.lock:
                self.active, self.run_id = False, None
            return False, r["error"].get("message", "turn/start failed")
        self.turn_id = self.turn_id or r["result"]["turn"]["id"]
        return True, None

    def abort(self):
        if self.turn_id:
            self.rpc("turn/interrupt", {"threadId": self.session_id, "turnId": self.turn_id})


OWNERS = {c.harness: c for c in (PiOwner, ClaudeOwner, CodexOwner)}


# ---------------------------------------------------------------------------
# Daemon
# ---------------------------------------------------------------------------

class Daemon:
    def __init__(self, state_dir, idle_expire, max_owners):
        self.state_dir = state_dir
        self.idle_expire = idle_expire
        self.max_owners = max_owners
        self.owners = {}   # odir -> Owner
        self.claimed = set()  # run ids already handed to a waiter
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

    def get_owner(self, odir, req):
        harness = req.get("harness") or "pi"
        cls = OWNERS.get(harness)
        if cls is None:
            raise RuntimeError("no live-steering backend for harness %r" % harness)
        with self.lock:
            owner = self.owners.get(odir)
            if owner and owner.proc.poll() is None:
                if owner.harness == harness:
                    return owner, False
                # The thread moved harness (fallback after a limit): the old
                # process cannot resume the other harness's session.
                owner.shutdown()
                self.owners.pop(odir, None)
            self.reap_stale(odir)
            os.makedirs(os.path.join(odir, "inbox"), exist_ok=True)
            os.makedirs(os.path.join(odir, "runs"), exist_ok=True)
            # Cap live processes per agent: reap LRU idle owners first.
            self.reap_lru()
            model = req.get("model") or (DEFAULT_MODEL if harness == "pi" else None)
            owner = cls(self, odir, req.get("session_id"), req.get("work_dir"), model,
                        req.get("system_prompt"), open(os.path.join(odir, "log"), "a"))
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
        # reconciliation; already-accepted ones live in the harness session).
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
        try:
            owner, started = self.get_owner(odir, req)
        except Exception as e:
            return {"ok": False, "error": "owner start failed: %s" % e}
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
                # Every message steered into a run has a worker waiting on it, and
                # they all wake on the same settled run. Only the first posts it.
                with self.lock:
                    rec["duplicate"] = rec.get("run") in self.claimed
                    self.claimed.add(rec.get("run"))
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
    p.set_defaults(func=lambda a: Daemon(a.state_dir, a.idle_expire, a.max_owners).serve())

    p = sub.add_parser("submit")
    common(p)
    p.add_argument("--msg-id", required=True)
    p.add_argument("--text", required=True)
    p.add_argument("--routing", choices=["steer", "followup", "stop", "new"], default="new")
    p.add_argument("--session-id", default=None)
    p.add_argument("--work-dir", default=None)
    p.add_argument("--harness", choices=sorted(OWNERS), default="pi")
    p.add_argument("--model", default=None, help="harness model id; pi takes provider/model")
    p.add_argument("--provider", default=None, help="pi only: joined as provider/model")
    p.add_argument("--system-prompt", default=None, help="applied when the process is spawned")
    p.add_argument("--timeout", type=int, default=600)
    p.set_defaults(func=lambda a: request(a.state_dir, {
        "action": "submit", "agent": a.agent, "channel": a.channel, "root": a.root,
        "msg_id": a.msg_id, "text": a.text, "routing": a.routing,
        "session_id": a.session_id, "work_dir": a.work_dir, "harness": a.harness,
        "model": "%s/%s" % (a.provider, a.model) if a.provider and a.model else a.model,
        "system_prompt": a.system_prompt, "timeout": a.timeout}))

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
