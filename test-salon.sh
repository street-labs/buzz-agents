#!/usr/bin/env bash
# Offline tests for salon-arbiter.py + salon config helpers.
set -u
cd "$(dirname "$0")"

fail() { echo "FAIL: $1"; exit 1; }

# 0. Embedded python payloads must compile as bash delivers them. Python inside a
# single-quoted bash string breaks silently when the python contains a single
# quote; bash -n cannot see it. Shipped three times (#16 rung-2 prompt, #17/#20
# SALON_FILTER), each time taking the salon fully silent.
./check-embedded-python.sh >/dev/null || fail "embedded python payload does not compile (run ./check-embedded-python.sh)"

# 1. Salon helpers parse + flag-off behavior (extracted from the watcher).
SALON_BLOCK="$(sed -n '/^AGENT_SALON_CHANNELS=/,/^}/p' agent-watcher.sh)"
[ -n "$SALON_BLOCK" ] || fail "salon config block not found"
bash -c "$SALON_BLOCK
! is_salon_channel z" || fail "flag off: nothing is a salon channel"
bash -c "$SALON_BLOCK
AGENT_SALON_CHANNELS='a b'
is_salon_channel b" || fail "configured channel not detected"
bash -c "$SALON_BLOCK
AGENT_SALON_CHANNELS='a b'
is_salon_channel a-b" && fail "substring channel matched (must be exact)"

# 2. Arbiter verdict parsing + silence-floor gates (offline, no network).
AGENT_SALON_CHANNELS="c" python3 - <<'PY' || fail "arbiter unit"
import importlib.util as u, json, os, sys
spec = u.spec_from_file_location("sa", "salon-arbiter.py"); m = u.module_from_spec(spec); spec.loader.exec_module(m)

def ans(who="nobody", why="nothing_to_me", conf=0.5, speak=0.2, depth=0.2):
    return {"answers": {"who_next": {"choice": who, "confidence": conf},
                        "why": {"choice": why}, "speak_now": {"noul": speak},
                        "depth": {"score": depth}}}

assert m.verdict(ans(), []) is None, "nobody must not tap"
assert m.verdict(ans(who="borg", why="social", conf=0.99, speak=0.99), []) is None, "social must not tap"
assert m.verdict(ans(who="borg", why="asked", conf=0.99, speak=0.99), []) is not None, "clear ask must tap"
assert m.verdict(ans(who="borg", why="asked", conf=0.5, speak=0.99), []) is None, "low conf must not tap"
assert m.verdict(ans(who="borg", why="asked", conf=0.99, speak=0.5), []) is None, "low speak_now must not tap"
assert m.verdict(ans(who="borg", why="expertise", conf=0.85, speak=0.99), [], "agent") is None, "agent msg needs higher conf"
assert m.verdict(ans(who="borg", why="expertise", conf=0.95, speak=0.99), [], "agent") is not None, "confident agent handoff taps"
assert m.depth_from_score(0.2) == "message" and m.depth_from_score(1.0) == "thread" and m.depth_from_score(1.8) == "session"
print("arbiter unit ok")
PY

# 3. Flag-off equivalence (AC-salon-flagoff-identical): the eligibility FILTER
# and the non-salon main-loop path are untouched by salon mode - assert the
# FILTER block is byte-identical to the pre-salon spec commit.
base="$(git show c93671f:agent-watcher.sh | sed -n "/^FILTER='/,/^'$/p")"
cur="$(sed -n "/^FILTER='/,/^'$/p" agent-watcher.sh)"
[ "$base" = "$cur" ] || fail "FILTER changed - flag-off equivalence broken"

# 4. Send gate unit tests (ENG-salon-tests): direct questions never dropped;
# malformed/absent gate verdict fails open (posts unchanged).
python3 - <<'PY' || fail "send-gate unit"
import importlib.util as u
spec = u.spec_from_file_location("sa", "salon-arbiter.py"); m = u.module_from_spec(spec); spec.loader.exec_module(m)

def gate(answ=0.9, worth=0.1):
    return {"answers": {"answered_elsewhere": {"noul": answ},
                        "still_worth_sending": {"noul": worth}}}

assert m.gate_verdict(gate(), False) == {"outcome": "drop"}, "answered elsewhere + redundant -> drop"
assert m.gate_verdict(gate(), True) is None, "direct ask must NEVER be dropped"
assert m.gate_verdict(gate(answ=0.5), False) is None, "low answered_elsewhere -> send"
assert m.gate_verdict(gate(worth=0.6), False) is None, "still adds value -> send"
assert m.gate_verdict({"answers": {"garbage": 1}}, False) is None, "malformed -> fail open"
assert m.gate_verdict(None, False) is None, "no data -> fail open"
print("send-gate unit ok")
PY

# 5. Watcher gate wiring: direct asks skip the gate entirely, and an empty
# gate verdict falls through to posting (fail-open at the call site).
GATE_BLOCK="$(sed -n '/Salon send gate (FR-salon-send-gate)/,/^  fi$/p' agent-watcher.sh)"
[ -n "$GATE_BLOCK" ] || fail "send gate block not found"
[[ "$GATE_BLOCK" == *'"$directly" != "1"'* ]] || fail "direct asks must bypass the gate"
[[ "$GATE_BLOCK" == *'if [ -n "$gv" ]'* ]] || fail "empty gate verdict must fail open (only drop when gv non-empty)"

# 6. Thread routing wiring (PR #17): the filter emits thread context, the agent-turn
# count and author kind; the arbiter pass enforces the consecutive-agent-turn cap.
SALON_FILTER="$(sed -n "/^SALON_FILTER='/,/^'$/p" agent-watcher.sh | sed "1s/^SALON_FILTER='//; \$s/^'$//")"
python3 - "$SALON_FILTER" <<'PY' || fail "salon filter thread context"
import base64, json, subprocess, sys, tempfile, os
src = sys.argv[1]
roster = tempfile.NamedTemporaryFile("w", suffix=".tsv", delete=False)
roster.write("pubborg\tborg\tpricing and marketing\npubcs\tcoffee-shop\tthe cafe app\n"); roster.close()
seen = tempfile.NamedTemporaryFile("w", delete=False); seen.close()
msgs = [
  {"id": "m1", "pubkey": "human1", "content": "hey coffee-shop, question", "created_at": 1, "tags": []},
  {"id": "m2", "pubkey": "pubcs", "content": "which part?", "created_at": 2, "tags": [["e", "m1", "", "root"]]},
  {"id": "m3", "pubkey": "human1", "content": "actually marketing and pricing", "created_at": 3, "tags": [["e", "m1", "", "root"]]},
]
out = subprocess.run([sys.executable, "-c", src, seen.name, "mepub", roster.name],
                     input=json.dumps(msgs), capture_output=True, text=True)
assert out.returncode == 0, out.stderr
rows = [l.split("\t") for l in out.stdout.strip().split("\n")]
assert all(len(r) == 7 for r in rows), rows
last = rows[-1]
assert last[0] == "m3" and last[2] == "m1" and last[6] == "human", last
ctx = base64.b64decode(last[4]).decode()
assert "agent @coffee-shop: which part?" in ctx and "actually marketing" in ctx, ctx
assert last[5] == "0", "human message resets the agent-turn counter"
m2 = [r for r in rows if r[0] == "m2"][0]
assert m2[6] == "agent" and m2[5] == "1", m2
os.unlink(roster.name); os.unlink(seen.name)
print("salon filter ok")
PY

PASS_BLOCK="$(sed -n '/^salon_arbiter_pass()/,/^}/p' agent-watcher.sh)"
[[ "$PASS_BLOCK" == *'SALON_AGENT_TURN_CAP:-3'* ]] || fail "agent turn cap missing"
[[ "$PASS_BLOCK" == *'"$ctx" "$author_kind"'* ]] || fail "thread context not passed to the arbiter"

echo "salon: all tests passed"
