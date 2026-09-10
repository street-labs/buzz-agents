#!/usr/bin/env bash
# Build one free agent slot ahead of time, so the thread that claims it next gets an
# incremental build instead of a cold one.
#
# A slot's path is what makes a build incremental, and recycling (see create_worktree
# in agent-watcher.sh) already preserves that for a slot handed straight from one
# thread to the next. What it cannot help with is a slot nobody has built in yet, or
# one whose build has drifted a long way behind main. This fills that gap using idle
# capacity, in slots nobody is using.
#
# Warming a slot a thread is actively working in would be pointless: two builds on one
# derived-data path serialise on Xcode's lock, so the agent would simply wait out the
# warm build. Only unclaimed slots are touched.
#
# The build command is not defined here. If the repo has an executable
# tools/agent-warm-slot.sh, that is run from the slot root; if it does not, this exits
# quietly. Nothing here knows what language or toolchain the project uses.
#
# Run from launchd on a timer, or by hand:  ./warm-slots.sh builder
set -uo pipefail

AGENT_NAME="${1:?usage: warm-slots.sh <agent-name>}"
STATE="$HOME/.buzz/agents/$AGENT_NAME"
WORKTREES="$STATE/worktrees.tsv"
LOCK="$HOME/.buzz/agents/.warm.lock"

[ -f "$STATE/agent.env" ] && . "$STATE/agent.env"
: "${AGENT_REPO:?set AGENT_REPO, or put it in $STATE/agent.env}"

log() { echo "[$AGENT_NAME warm] $*"; }

# One warm at a time across every agent. These builds are heavy enough that two at
# once make the machine slower for the live agents, which defeats the purpose.
exec 9>"$LOCK"
flock -n 9 || { log "another warm is running"; exit 0; }

warm_cmd="$AGENT_REPO/tools/agent-warm-slot.sh"
[ -x "$warm_cmd" ] || { log "no executable tools/agent-warm-slot.sh in the repo, nothing to do"; exit 0; }

# Idle means: load below core count, and nobody else is building. Checked before we
# start; a build that begins on a loaded machine takes several times as long and slows
# every live agent while it does.
# WARM_FORCE=1 skips it, for running by hand when you know what else is on the box.
if [ "${WARM_FORCE:-0}" != "1" ]; then
    cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 8)
    load=$(uptime | sed -E 's/.*averages?: *//' | awk '{print int($1)}')
    if [ "$load" -ge "$cores" ]; then
        log "load $load on $cores cores, too busy"
        exit 0
    fi
    if pgrep -f "[x]codebuild|[g]radle" >/dev/null 2>&1; then
        log "a build is already running"
        exit 0
    fi
fi

repo_name="$(basename "$AGENT_REPO")"
base_dir="$(dirname "$AGENT_REPO")/${repo_name}-worktrees"
[ -d "$base_dir" ] || exit 0

( cd "$AGENT_REPO" && git fetch -q origin 2>/dev/null ) || true
head_sha="$(git -C "$AGENT_REPO" rev-parse origin/main 2>/dev/null)" || exit 0

for slot in "$base_dir/$AGENT_NAME-slot-"*; do
    [ -d "$slot" ] || continue
    # Claimed by a live thread.
    flock "$WORKTREES" grep -qF "	$slot	" "$WORKTREES" 2>/dev/null && continue
    # Holds work somebody may still want. Never reset it to warm it.
    [ -n "$(git -C "$slot" status --porcelain 2>/dev/null)" ] && continue
    [ -n "$(git -C "$slot" log --oneline HEAD --not --remotes 2>/dev/null)" ] && continue

    gitdir="$(git -C "$slot" rev-parse --absolute-git-dir 2>/dev/null)" || continue
    marker="$gitdir/agent-warmed-sha"
    # Rewarm whenever main has moved. There is no time-based throttle on purpose:
    # rewarming an already-warm slot is itself incremental and costs minutes, and the
    # idle check above is what stops this running when the machine is busy.
    [ "$(cat "$marker" 2>/dev/null)" = "$head_sha" ] && continue

    log "warming $slot at ${head_sha:0:8}"
    if ! ( cd "$slot" && git checkout -q --detach "$head_sha" && git reset -q --hard "$head_sha" && git clean -qfd ); then
        log "could not reset $slot, skipping"
        continue
    fi
    if ( cd "$slot" && "$warm_cmd" ); then
        log "warmed $slot"
    else
        log "warm failed for $slot"
    fi
    exit 0   # one slot per run; the timer comes back for the next
done

log "no slot needs warming"
