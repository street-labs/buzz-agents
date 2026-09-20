#!/usr/bin/env bash
# Offline tests for jev-stall.py. No network (the prod call path is exercised
# only when AGENT_JEV_STALL=1 and a real key is configured).
set -u
cd "$(dirname "$0")"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Flag off -> fail-open (empty output, nonzero exit).
unset AGENT_JEV_STALL 2>/dev/null || true
out="$(python3 jev-stall.py "building, will report back" 2>/dev/null)"
[ -z "$out" ] || fail "flag off should print nothing"

# 2. verdict() parses a real response shape; low confidence is dropped.
python3 - <<'PY' || fail "verdict parse"
import importlib.util as u, json, os
os.environ["AGENT_JEV_STALL"] = "1"
spec = u.spec_from_file_location("js", "jev-stall.py"); m = u.module_from_spec(spec); spec.loader.exec_module(m)
data = {"answers": {"state": {"choice": "wip", "confidence": 0.88}}}
v = m.verdict(data)
assert v == {"state": "wip", "confidence": 0.88}, v
for bad in [{}, {"answers": {}}, {"answers": {"state": {}}}]:
    try:
        m.verdict(bad); raise SystemExit("bad shape accepted")
    except Exception:
        pass
print("parse ok")
PY

# 3. Flag on but no key -> fail-open.
out="$(AGENT_JEV_STALL=1 HOME="$(mktemp -d)" python3 jev-stall.py "done, PR is up" 2>/dev/null)"
[ -z "$out" ] || fail "missing key should print nothing"

echo "jev-stall: all tests passed"

# 4. Decision matrix for stall_watch_record in agent-watcher.sh: jev decides,
#    regex is the fallback, declared waits always arm.
T=$(mktemp -d); export T
bash -n agent-watcher.sh || { echo "FAIL: agent-watcher.sh does not parse"; exit 1; }
{
  python3 - <<'PY'
import re
s = open("agent-watcher.sh").read()
for name in ["is_thread_resolved", "stall_is_open_ended", "stall_delete", "stall_watch_record"]:
    print(re.search(rf"^{name}\(\) \{{.*?^\}}", s, re.S | re.M).group(0))
print(re.search(r"^STALL_ENDWORDS=.*$", s, re.M).group(0))
PY
  cat <<'SH'
STALL="$T/stall.tsv"; : > "$STALL"
export AGENT_JEV_STALL=1
export JEV_STALL_SCRIPT="$T/fake-jev.py"
cat > "$T/fake-jev.py" <<'PY'
import json, os, sys
v = os.environ.get("FAKE_VERDICT", "")
if not v: sys.exit(1)
print(json.dumps({"state": v, "confidence": 0.9}))
PY
armed() { [ -s "$STALL" ] && echo armed || echo dropped; }
fa=0
check() { # $1=expected $2=description
  [ "$1" = "$(armed)" ] || { echo "FAIL: $2 (got $(armed))"; fa=1; }
  : > "$STALL"
}
WIP="building, will report back shortly"
DONE="Done. PR: https://github.com/x/y/pull/1"
FAKE_VERDICT=wip    stall_watch_record r1 c1 "$DONE" 0;  check armed   "jev wip arms even a done-looking reply"
FAKE_VERDICT=done   stall_watch_record r2 c1 "$WIP" 0;   check dropped "jev done drops the watch"
FAKE_VERDICT=blocked stall_watch_record r3 c1 "$DONE" 0; check armed   "jev blocked keeps the watch"
FAKE_VERDICT=       stall_watch_record r4 c1 "$WIP" 0;   check armed   "no jev verdict + open-ended regex -> fallback arms"
FAKE_VERDICT=       stall_watch_record r5 c1 "$DONE" 0;  check dropped "no jev verdict + resolved regex -> fallback drops"
unset AGENT_JEV_STALL
                    stall_watch_record r6 c1 "$WIP" 0;   check armed   "jev off: regex fallback still arms"
                    stall_watch_record r7 c1 "$DONE" 60; check armed   "declared wait always arms"
rm -rf "$T"
[ "$fa" -eq 0 ] && echo "decision matrix: ok"
exit "$fa"
SH
} | bash
exit $?
