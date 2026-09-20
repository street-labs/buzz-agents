#!/usr/bin/env python3
"""Opt-in Jev stall verdict for agent-watcher.sh.

Given an agent's last thread reply, ask the TypeSafe System One API (Jev) whether
the work it describes is finished. Prints a one-line JSON verdict only when the
answer is actionable:
    {"state":"done","confidence":0.91}    # drop the stall watch
    {"state":"wip","confidence":0.88}     # keep watching (mid-task)
    {"state":"blocked","confidence":0.85} # keep watching (needs input)
Any failure (flag off, no key, network error, low confidence) prints NOTHING and
exits 1: the watcher falls back to the regex heuristic in stall_is_open_ended.

Fail-open by design - Jev is an accelerant, never a dependency.

Usage: jev-stall.py <reply-content>
Config via env:
    AGENT_JEV_STALL=1         opt-in; anything else disables this script
    TYPESAFE_API_KEY          or ~/.typesafe/key
    TYPESAFE_API_URL          override for tests (default prod endpoint)
    JEV_STALL_CONF_MIN        min state confidence to act (default 0.8)
"""
import json
import os
import sys
import urllib.request

ENDPOINT = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/systemone")
CONF_MIN = float(os.environ.get("JEV_STALL_CONF_MIN", "0.8"))


def ask(content):
    """One Jev call for one reply. Returns the answers dict; raises on failure."""
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        kf = os.path.expanduser("~/.typesafe/key")
        if os.path.exists(kf):
            key = open(kf).read().strip()
    if not key:
        raise RuntimeError("no API key")
    if not content:
        raise RuntimeError("empty reply")

    questions = {
        "state": {
            "type": "choice",
            "instructions": "Does this agent reply describe finished work or work still in progress",
            "criteria": {
                "done": "Task complete, result delivered, or a question fully answered; nothing owed",
                "wip": "Work is mid-flight: running, building, will report back, more coming",
                "blocked": "Waiting on something external or stuck; cannot continue without input",
            },
        },
    }
    body = json.dumps({"state": content, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def verdict(data):
    """Parse an answers dict into the verdict; raises on bad shape."""
    a = data["answers"]["state"]
    return {"state": a["choice"], "confidence": round(float(a["confidence"]), 3)}


def main():
    if os.environ.get("AGENT_JEV_STALL", "0") != "1":
        sys.exit(1)
    content = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        v = verdict(ask(content))
    except Exception as e:
        print(f"jev-stall: {e}", file=sys.stderr)
        sys.exit(1)
    # Low confidence on an ambiguous reply = fall back to the regex heuristic.
    if v["confidence"] < CONF_MIN:
        sys.exit(1)
    print(json.dumps(v))


if __name__ == "__main__":
    main()
