#!/usr/bin/env bash
# A resumed branch-pr thread whose slot row was reclaimed gets a worktree from
# create_worktree (which resurrects its branch), never the owner's checkout.
# Run: bash test-resume-reclaimed.sh
set -u
cd "$(dirname "$0")"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The resume/new-thread worktree selection inside worker().
python3 -c '
import re
s = open("agent-watcher.sh").read()
print(re.search(r"^  if \[ -n \"\$sid\" \]; then\n    # Resuming.*?^  fi\n", s, re.S | re.M).group(0))' > "$T/block.sh"
create_worktree() { mkdir -p "$T/slot"; echo "$T/slot"; }
worktree_failed() { echo FAILED; }
AGENT_NAME=t; root_id=r; channel_id=c; msg_id=m; AGENT_REPO="$T/owner"; mkdir -p "$AGENT_REPO"
fail=0
run() { sid=s1; work_dir="$1"; AGENT_GUARDRAIL="$2"; . "$T/block.sh" 2>/dev/null; echo "$work_dir"; }
[ "$(run "" branch-pr)" = "$T/slot" ] || { echo "FAIL: branch-pr with no row got $(run "" branch-pr), want the restored slot"; fail=1; }
[ "$(run "" direct-main)" = "$AGENT_REPO" ] || { echo "FAIL: direct-main should resume in the repo"; fail=1; }
[ "$(run "$T/gone" branch-pr)" = "$T/slot" ] || { echo "FAIL: missing path should be replaced"; fail=1; }
[ "$fail" = 0 ] && echo ok
exit "$fail"
