#!/usr/bin/env bash
# An empty reply is only a failure when the message addressed this agent. Follow-along
# turns stay silent on purpose: no re-prompt, no placeholder. Run: bash test-reply-guard.sh
set -u
cd "$(dirname "$0")"
block="$(sed -n '/# Reply guard (mirrors/,/no reply produced - check/p' agent-watcher.sh)"
printf '%s' "$block" | grep -q 'no reply produced' || { echo "FAIL: could not extract guard block"; exit 1; }
eval "guard() { $block
}"
marker="$(mktemp)"
invoke_harness() { echo 1 > "$marker"; }  # the watcher backgrounds this, so a variable would not survive
wait_with_timeout() { :; }
extract_harness_field() { :; }
set_session() { :; }
AGENT_NAME=t; STATE=/tmp; msg_id=m; turn_harness=x; harness_model=x; work_dir=.; SYSTEM_PROMPT=x
on_fallback=0; new_sid=; sid=; root_id=r

fail=0
check() { # name, directly, input reply, watcher action, want prompted, want reply prefix
  echo 0 > "$marker"; directly=$2; reply=$3; watcher_action=$4
  guard >/dev/null
  wait; prompted="$(cat "$marker")"
  if [ "$prompted" != "$5" ] || [[ "$reply" != "$6"* ]] || { [ -z "$6" ] && [ -n "$reply" ]; }; then
    echo "FAIL: $1 (prompted=$prompted reply='$reply')"; fail=1
  fi
}
check "untagged, silent -> nothing"       0 ""     ""     0 ""
check "tagged, silent -> guard fires"     1 ""     ""     1 "(no reply produced"
check "tagged, bare mute -> no guard"     1 ""     "mute" 0 ""
check "untagged, answered -> untouched"   0 "hi"   ""     0 "hi"
check "tagged, answered -> untouched"     1 "hi"   ""     0 "hi"
rm -f "$marker"
[ "$fail" -eq 0 ] && echo "ok"
exit "$fail"
