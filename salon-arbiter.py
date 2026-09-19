#!/usr/bin/env python3
"""Salon arbiter: decide who should take the next turn in a salon channel.

Jev backend only (the LLM rung and deterministic floor live in the watcher).
Same fail-open contract as jev-triage.py: prints a one-line JSON verdict when a
high-confidence tap should occur, prints NOTHING and exits 1 otherwise (flag
off, no key, API error, low confidence, social/no-op verdict). The watcher
treats empty output as "nobody talks" -> silence floor.

Usage:
    salon-arbiter.py <message-content> <my-name> <roster-file> [thread-context] [author-kind]
    salon-arbiter.py --gate <draft-reply> [recent-thread]   (send gate)
Config via env:
    TYPESAFE_API_KEY          or ~/.typesafe/key
    TYPESAFE_API_URL          override for tests (default prod endpoint)
    SALON_CONF_MIN            min who_next confidence to tap (default 0.8)
    SALON_SPEAK_MIN           min speak_now to tap (default 0.8)

Verdict shape: {"who":"<name>","why":"asked|correcting|expertise","depth":"message|thread|session","confidence":0.93}
Gate verdict:    {"outcome":"drop"}  (only when dropping is warranted; anything
                 else prints nothing = send unchanged)
"""
import json
import os
import sys
import urllib.request

ENDPOINT = os.environ.get("TYPESAFE_API_URL", "https://api.typesafe.ai/v1/systemone")
CONF_MIN = float(os.environ.get("SALON_CONF_MIN", "0.8"))
SPEAK_MIN = float(os.environ.get("SALON_SPEAK_MIN", "0.8"))
# Agent-authored messages need a higher bar than human ones (loop pressure).
AGENT_CONF_MIN = float(os.environ.get("SALON_AGENT_CONF_MIN", "0.9"))
# why values that may earn a tap; social/nothing_to_me never tap (silence floor).
TAPPABLE_WHY = {"asked", "correcting", "expertise"}


def _key():
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if not key:
        kf = os.path.expanduser("~/.typesafe/key")
        if os.path.exists(kf):
            key = open(kf).read().strip()
    if not key:
        raise RuntimeError("no API key")
    return key


def ask(content, my_name, roster_names, thread_context, descriptions=None, author_kind="human"):
    key = _key()
    if not content:
        raise RuntimeError("empty message")

    descriptions = descriptions or {}
    criteria = {n: descriptions.get(n, f"agent @{n}") for n in roster_names if n != my_name}
    if my_name:
        criteria[my_name] = f"me, the watcher agent @{my_name}"
    criteria["nobody"] = (
        "no agent should take the next turn: the humans are talking to each other, "
        "the turn is complete, or the message does not invite a useful response"
    )
    questions = {
        "who_next": {
            "type": "choice",
            "instructions": (
                "Who is the best NEXT participant to speak after this message in this "
                "conversation, judged by whose described expertise the latest message "
                "now needs - not by who was asked and not by who spoke last. A topic "
                "shift mid-thread moves the turn to a different agent; the agent already "
                "engaged is only a tie-breaker between otherwise equal candidates."
            ),
            "criteria": criteria,
        },
        "why": {
            "type": "choice",
            "instructions": "Why would that participant take the next turn",
            "criteria": {
                "asked": "someone directly asked or addressed that agent, or handed off to it",
                "correcting": "the agent has a factual correction that prevents an error",
                "expertise": "the agent clearly has unique relevant information",
                "social": "banter, acknowledgement, restatement, or humans talking to each other",
                "nothing_to_me": "nothing for any agent here",
            },
        },
        "depth": {
            "type": "score",
            "instructions": "How much context the reply needs (0=message only, 1=whole thread, 2=thread plus the agent's own working memory of it)",
            "criteria": [
                "current message alone is enough",
                "whole thread context needed",
                "thread plus prior work/memory needed",
            ],
        },
        "speak_now": {
            "type": "noul",
            "instructions": (
                "Would it be natural (not interruptive) for the chosen agent to take the "
                "next turn right now, the way a knowledgeable colleague listening in "
                "would. Interjecting in a human-to-human exchange is never natural."
            ),
        },
    }
    state = content
    if my_name:
        roster_lines = ", ".join(
            f"@{n}" + (f" ({descriptions[n]})" if n in descriptions else "")
            for n in roster_names if n != my_name
        )
        state = f"watcher agent: @{my_name}; roster: {roster_lines}\n\nmessage:\n{content}"
    state = f"latest message author: {author_kind}\n" + state
    if thread_context:
        state += f"\n\nconversation so far (oldest first, latest message last):\n{thread_context[-4000:]}"
    if author_kind == "agent":
        state += ("\n\nNote: the latest message is from an agent, not a human. An "
                  "agent-to-agent turn needs a higher bar than answering a human: only "
                  "continue when the message asks something specific or clearly needs "
                  "another agent's expertise.")
    body = json.dumps({"state": state, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def depth_from_score(score):
    return "message" if score < 0.5 else ("thread" if score < 1.5 else "session")


def verdict(data, roster_names, author_kind="human"):
    a = data["answers"]
    who = a["who_next"]["choice"]
    why = a["why"]["choice"]
    speak = float(a["speak_now"]["noul"])
    conf = float(a["who_next"]["confidence"])
    depth = depth_from_score(float(a["depth"]["score"]))
    # Silence floor: social/no-op or low confidence -> nobody talks.
    floor = AGENT_CONF_MIN if author_kind == "agent" else CONF_MIN
    if who == "nobody" or why not in TAPPABLE_WHY or speak < SPEAK_MIN or conf < floor:
        return None
    return {"who": who, "why": why, "depth": depth, "confidence": round(conf, 3)}


def ask_gate(draft, recent_thread):
    key = _key()
    questions = {
        "answered_elsewhere": {
            "type": "noul",
            "instructions": "Has this already been said or answered by someone else in the newer messages",
        },
        "still_worth_sending": {
            "type": "noul",
            "instructions": "Does this draft reply still add something the humans need, given the newer messages",
        },
    }
    state = f"draft reply:\n{draft}"
    if recent_thread:
        state += f"\n\nrecent thread (newest last):\n{recent_thread[-4000:]}"
    body = json.dumps({"state": state, "model": "jev-latest", "questions": questions}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST",
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def gate_verdict(data, direct_ask):
    """Drop only when the reply was answered elsewhere; never drop a direct ask
    (no-ghosting). adapt/defer are folded into send in slice 1 - upgrading later.
    Any malformed response fails open (None = send unchanged)."""
    try:
        a = data["answers"]
        answered = float(a["answered_elsewhere"]["noul"])
        worth = float(a["still_worth_sending"]["noul"])
    except Exception:
        return None
    if direct_ask or answered < 0.8 or worth >= 0.5:
        return None
    return {"outcome": "drop"}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--gate":
        draft = sys.argv[2] if len(sys.argv) > 2 else ""
        recent = sys.argv[3] if len(sys.argv) > 3 else ""
        direct_ask = "--direct" in sys.argv
        try:
            v = gate_verdict(ask_gate(draft, recent), direct_ask)
        except Exception as e:
            print(f"salon-arbiter: {e}", file=sys.stderr)
            sys.exit(1)
        if not v:
            sys.exit(1)
        print(json.dumps(v))
        return
    content = sys.argv[1] if len(sys.argv) > 1 else ""
    my_name = sys.argv[2] if len(sys.argv) > 2 else ""
    roster_file = sys.argv[3] if len(sys.argv) > 3 else ""
    thread_context = sys.argv[4] if len(sys.argv) > 4 else ""
    author_kind = sys.argv[5] if len(sys.argv) > 5 else "human"
    names = []
    descriptions = {}
    if roster_file and os.path.exists(roster_file):
        try:
            with open(roster_file) as f:
                for l in f:
                    if "\t" not in l:
                        continue
                    cols = l.rstrip("\n").split("\t")
                    names.append(cols[1].strip())
                    if len(cols) > 2 and cols[2].strip():
                        descriptions[cols[1].strip()] = cols[2].strip()
        except Exception:
            names = []
    if my_name and my_name not in names:
        names.append(my_name)
    try:
        v = verdict(ask(content, my_name, names, thread_context, descriptions, author_kind), names, author_kind)
    except Exception as e:
        print(f"salon-arbiter: {e}", file=sys.stderr)
        sys.exit(1)
    if not v:
        sys.exit(1)
    print(json.dumps(v))


if __name__ == "__main__":
    main()
