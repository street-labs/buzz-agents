#!/usr/bin/env bash
# Startup smoke: run the watcher's top level against an unreachable relay and fail on
# an unbound variable or syntax error before the main loop. Run: bash test-startup.sh
set -u
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.buzz/agents"; cp ./*.sh ./*.py "$T/.buzz/agents/"
printf 'k\n' > "$T/key"
printf 'AGENT_NAME=smoke\nAGENT_KEY_FILE=%s/key\nAGENT_REPO=%s\nBUZZ_RELAY_URL=http://127.0.0.1:9\nOWNER=ffff\nAGENT_MODEL=smoke\n' "$T" "$T" > "$T/smoke.env"
HOME="$T" bash "$T/.buzz/agents/agent-watcher.sh" "$T/smoke.env" > "$T/out" 2>&1 & pid=$!
sleep 8; kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
if grep -E 'unbound variable|syntax error|command not found' "$T/out"; then echo "FAIL: watcher startup"; exit 1; fi
echo ok
