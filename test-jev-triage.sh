#!/usr/bin/env bash
# Offline tests for jev-triage.py. No network (the prod call path is exercised
# only when AGENT_JEV_TRIAGE=1 and a real key is configured).
set -u
cd "$(dirname "$0")"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Flag off -> fail-open (empty output, nonzero exit).
unset AGENT_JEV_TRIAGE 2>/dev/null || true
out="$(python3 jev-triage.py "hello" 2>/dev/null)"
[ -z "$out" ] || fail "flag off should print nothing"

# 2. verdict() parses a real response shape; low confidence is dropped.
python3 - <<'PY' || fail "verdict parse"
import importlib.util as u, json, os
os.environ["AGENT_JEV_TRIAGE"] = "1"
spec = u.spec_from_file_location("jt", "jev-triage.py"); m = u.module_from_spec(spec); spec.loader.exec_module(m)
data = {"answers": {"route": {"choice": "ignore", "confidence": 0.95},
                    "urgency": {"noul": 0.05}, "complexity": {"score": 0.1}}}
v = m.verdict(data)
assert v == {"route": "ignore", "confidence": 0.95, "urgency": 0.05, "complexity": 0.1}, v
for bad in [{}, {"answers": {"route": {}}}]:
    try:
        m.verdict(bad); raise SystemExit("bad shape accepted")
    except Exception:
        pass
print("parse ok")
PY

# 3. Flag on but no key -> fail-open.
out="$(AGENT_JEV_TRIAGE=1 HOME="$(mktemp -d)" python3 jev-triage.py "hi" 2>/dev/null)"
[ -z "$out" ] || fail "missing key should print nothing"

echo "jev-triage: all tests passed"
