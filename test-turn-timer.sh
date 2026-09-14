#!/usr/bin/env bash
# Tests wait_with_timeout in agent-watcher.sh. The regression: killing the timer left its
# sleep orphaned, holding the worker's output pipe open for the whole MODEL_TIMEOUT.
# Run: bash test-turn-timer.sh
set -u
cd "$(dirname "$0")"
eval "$(sed -n '/^wait_with_timeout() {/,/^}/p' agent-watcher.sh)"
type wait_with_timeout >/dev/null 2>&1 || { echo "FAIL: could not extract wait_with_timeout"; exit 1; }

# A turn that finishes on its own: the pipe must close as soon as it does.
MODEL_TIMEOUT=20; SECONDS=0
: "$(sleep 0.2 & wait_with_timeout $!)"
[ "$SECONDS" -lt 5 ] || { echo "FAIL: pipe held open ${SECONDS}s after the turn ended"; exit 1; }
echo "ok: finished turn releases the pipe"

# A turn that hangs: the timer must kill it.
MODEL_TIMEOUT=1; SECONDS=0
: "$(sleep 30 & wait_with_timeout $!)"
[ "$SECONDS" -lt 10 ] || { echo "FAIL: hung turn not killed after ${SECONDS}s"; exit 1; }
echo "ok: hung turn is killed at the timeout"
