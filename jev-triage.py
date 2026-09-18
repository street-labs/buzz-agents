#!/usr/bin/env python3
"""Opt-in Jev triage for agent-watcher.sh.

Given one message, ask the TypeSafe System One API (Jev) whether the watcher
should act on it or ignore it. On a high-confidence "ignore", prints a one-line
JSON verdict:
    {"route":"ignore","confidence":0.93,"urgency":0.1,"complexity":0.2}
Any failure (flag off, no key, network error, low confidence) prints NOTHING
and exits 1: the watcher treats that as "no verdict, behave as today".

Fail-open by design - Jev is an accelerant, never a dependency.

Usage: jev-triage.py <message-content> [agent-name] [roster-file]
Config via env:
    AGENT_JEV_TRIAGE=1        opt-in; anything else disables this script
    TYPESAFE_API_KEY          or ~/.typesafe/key
    TYPESAFE_API_URL          override for tests (default prod endpoint)
    JEV_CONF_MIN              min route confidence to act (default 0.8)
"""
import json
import os
import sys
import urllib.request

ENDPOINT = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/systemone")
CONF_MIN = float(os.environ.get("JEV_CONF_MIN", "0.8"))


def ask(content, name="", roster_file=""):
    """One Jev call for one message. Returns the answers dict; raises on failure."""
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        kf = os.path.expanduser("~/.typesafe/key")
        if os.path.exists(kf):
            key = open(kf).read().strip()
    if not key:
        raise RuntimeError("no API key")
    if not content:
        raise RuntimeError("empty message")

    # Route criteria: act vs ignore only. "agent vs human" is the existing routing
    # (p-tags, roster) - this script only drops high-confidence noise.
    questions = {
        "route": {
            "type": "choice",
            "instructions": "Should the watcher act on this message or ignore it",
            "criteria": {
                "act": "Asks for, or plausibly needs, a reply or action from an agent",
                "ignore": "FYI only, status noise, bot chatter, or no action needed",
            },
        },
        "urgency": {"type": "noul", "instructions": "Needs a response within the hour"},
        "complexity": {
            "type": "score",
            "instructions": "How much reasoning this needs",
            "criteria": [
                "Trivial pattern match, no reasoning",
                "Some judgment but routine",
                "Needs multi-step reasoning or context",
            ],
        },
    }
    state = content
    if name:
        # Per-message reference context: who the agent is, who else is on the roster.
        names = []
        if roster_file and os.path.exists(roster_file):
            try:
                with open(roster_file) as f:
                    names = [l.split("\t")[1].strip() for l in f if "\t" in l]
            except Exception:
                names = []
        state = f"watcher agent: @{name}; roster: {', '.join('@' + n for n in names)}\n\nmessage:\n{content}"

    body = json.dumps({"state": state, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def verdict(data):
    """Parse an answers dict into the verdict; raises on bad shape."""
    a = data["answers"]["route"]
    return {
        "route": a["choice"],
        "confidence": round(float(a["confidence"]), 3),
        "urgency": round(float(data["answers"]["urgency"]["noul"]), 3),
        "complexity": round(float(data["answers"]["complexity"]["score"]), 3),
    }


def main():
    if os.environ.get("AGENT_JEV_TRIAGE", "0") != "1":
        sys.exit(1)
    content = sys.argv[1] if len(sys.argv) > 1 else ""
    name = sys.argv[2] if len(sys.argv) > 2 else ""
    roster = sys.argv[3] if len(sys.argv) > 3 else ""
    try:
        v = verdict(ask(content, name, roster))
    except Exception as e:
        print(f"jev-triage: {e}", file=sys.stderr)
        sys.exit(1)
    # Low confidence on an ambiguous message = fall back to existing behavior.
    if v["route"] != "ignore" or v["confidence"] < CONF_MIN:
        sys.exit(1)
    print(json.dumps(v))


if __name__ == "__main__":
    main()
