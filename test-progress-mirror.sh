#!/usr/bin/env bash
# Tests for progress mirroring (mirror_progress) in agent-watcher.sh.
# Extracts the function from the watcher so the test can't drift.
set -euo pipefail
cd "$(dirname "$0")"

fn="$(sed -n '/^mirror_progress() {/,/^}/p' agent-watcher.sh)"
[ -n "$fn" ] || { echo "FAIL: could not extract mirror_progress"; exit 1; }
eval "$fn"

AGENT_NAME=test
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
out_file="$tmp/events.jsonl"
log="$tmp/sends.log"
# Stub BUZZ: record sends, one argv-set per line.
BUZZ="$tmp/stub-buzz"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$log" > "$BUZZ"
chmod +x "$BUZZ"

# Emit a pi --mode json event stream: $1=file, then assistant texts (last = final).
emit() {
  local f="$1"; shift
  python3 - "$f" "$@" <<'PY'
import json, sys
f, texts = sys.argv[1], sys.argv[2:]
with open(f, 'w') as fh:
    fh.write(json.dumps({"type": "session", "id": "s1"}) + "\n")
    for t in texts:
        fh.write(json.dumps({"type": "message_start", "message": {"role": "assistant"}}) + "\n")
        # thinking + tool noise must never be mirrored
        fh.write(json.dumps({"type": "message_update",
                             "assistantMessageEvent": {"type": "text_start"}}) + "\n")
        fh.write(json.dumps({"type": "tool_execution_start", "tool_name": "bash"}) + "\n")
        fh.write(json.dumps({"type": "message_end", "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": "secret thoughts"},
                        {"type": "text", "text": t}]}}) + "\n")
PY
}

run_mirror() { # $1=timeout_secs $2=MIN_SECS
  ( PROGRESS_MIRROR_POLL=1 PROGRESS_MIRROR_MIN_SECS="${2:-45}" \
      mirror_progress "$out_file" chan1 rootX >/dev/null 2>&1 ) &
  local pid=$!
  sleep "$1"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  # posts are only visible after a poll; wait for quiescence
  sleep 1
  local n=0; [ -f "$log" ] && n="$(wc -l < "$log" | tr -d ' ')"
  echo "$n"
}

posts() { # print posted contents, one per line
  [ -f "$log" ] && grep -o '\-\-content .*' "$log" | sed 's/^--content //' || true
}

fails=0
check() { local name="$1" expected="$2" got="$3"
  if [ "$got" = "$expected" ]; then echo "ok: $name"
  else echo "FAIL: $name"; echo "  expected: [$expected]"; echo "  got:      [$got]"; fails=1; fi
}

# 1. Intermediate vs final: 2 intermediates + final -> exactly the 2 intermediates,
#    final never mirrored (one-behind).
rm -f "$log"; emit "$out_file" "found the bug" "tests pass, pushing" "Pushed to main. PR #7 open."
check "mirror intermediates only" "2" "$(run_mirror 2 0)"
check "final reply not mirrored" "found the bug
tests pass, pushing" "$(posts)"

# 2. Correct thread routing: every send goes to the channel + thread root.
check "routes to channel+root" "0" "$(grep -vc 'chan1' "$log" || true)"
check "reply-to is thread root" "0" "$(grep -vc 'reply-to rootX' "$log" || true)"

# 3. Dedupe: repeated identical updates post once.
rm -f "$log"; emit "$out_file" "building" "building" "building" "done, PR merged."
check "dedupe repeated updates" "1" "$(run_mirror 2 0)"

# 4. Throttle: the first update goes out immediately, repeats inside the window
#    are dropped, not queued (final reply never mirrored, so 1 post total).
rm -f "$log"; emit "$out_file" "step one" "step two" "step three" "all done."
check "throttle drops rapid updates" "1" "$(run_mirror 2 1000)"

# 5. Single-message turn (the common quick answer): nothing mirrored at all.
rm -f "$log"; emit "$out_file" "Just the final answer."
check "no intermediates -> no mirror" "0" "$(run_mirror 2 0)"

[ "$fails" = 0 ] && echo "all progress-mirror tests passed" || exit 1
