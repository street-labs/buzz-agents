#!/usr/bin/env bash
# Offline tests for salon-arbiter.py + salon config helpers.
set -u
cd "$(dirname "$0")"

fail() { echo "FAIL: $1"; exit 1; }

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
assert m.depth_from_score(0.2) == "message" and m.depth_from_score(1.0) == "thread" and m.depth_from_score(1.8) == "session"
print("arbiter unit ok")
PY

# 3. Flag-off equivalence (AC-salon-flagoff-identical): the eligibility FILTER
# and the non-salon main-loop path are untouched by salon mode - assert the
# FILTER block is byte-identical to the pre-salon spec commit.
base="$(git show c93671f:agent-watcher.sh | sed -n "/^FILTER='/,/^'$/p")"
cur="$(sed -n "/^FILTER='/,/^'$/p" agent-watcher.sh)"
[ "$base" = "$cur" ] || fail "FILTER changed - flag-off equivalence broken"

echo "salon: all tests passed"
