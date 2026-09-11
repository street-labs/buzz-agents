#!/usr/bin/env bash
# Run a long job detached, and make sure the thread hears how it ended - including
# when nothing survives to say so.
#
# An agent that starts a build and ends its turn has no waiter left. The shell holding
# the job dies with the session, so a build that finishes tells nobody, and a build
# that is killed tells nobody either; the agent sits idle until a human notices. That
# is the expensive case, because it looks exactly like work in progress.
#
# So the job is recorded on disk instead of in a live shell. The watcher polls with
# --check once per cycle and posts the outcome into the thread, which re-summons the
# agent: the message @-mentions it, and an agent's own key is in peers.txt.
#
#   agent-job.sh --label "alpha build" -- make ios-build
#   agent-job.sh --check          # the watcher, once per poll cycle
#
# --channel/--thread default to BUZZ_CHANNEL/BUZZ_THREAD, which the watcher exports
# into every turn, so an agent normally passes neither.
set -uo pipefail

AGENT_NAME="${AGENT_NAME:?set AGENT_NAME}"
JOBS="$HOME/.buzz/agents/$AGENT_NAME/jobs"
BUZZ="${BUZZ:-$(command -v buzz || echo "$HOME/.buzz/bin/buzz")}"
mkdir -p "$JOBS"

field() { sed -n "s/^$2=//p" "$1" | tail -1; }

# Report every job that has stopped, one message each, then forget it. A job is over
# when its rc file exists (it ran to the end) or when its pid is gone without one (it
# was killed, and nothing else anywhere will report that).
check() {
    for job in "$JOBS"/*.job; do
        [ -f "$job" ] || continue
        rc="$(cat "${job%.job}.rc" 2>/dev/null)"
        if [ -z "$rc" ]; then
            # ponytail: pid liveness only. A recycled pid keeps a dead job looking
            # alive; check the ppid chain if that ever actually bites.
            kill -0 "$(field "$job" pid)" 2>/dev/null && continue
            rc="killed"
        fi
        label="$(field "$job" label)"; log="$(field "$job" log)"
        if [ "$rc" = "killed" ]; then
            msg="@$AGENT_NAME job \"$label\" stopped without a verdict - its shell died. Log: $log"
        else
            msg="@$AGENT_NAME job \"$label\" finished rc=$rc. Log: $log"
        fi
        if "$BUZZ" messages send --channel "$(field "$job" channel)" \
             --reply-to "$(field "$job" thread)" --content "$msg" >/dev/null 2>&1; then
            rm -f "$job" "${job%.job}.rc"
        else
            echo "[$AGENT_NAME job] could not post the outcome of $job" >&2
        fi
    done
}

label=""; log=""
channel="${BUZZ_CHANNEL:-}"; thread="${BUZZ_THREAD:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   check; exit 0 ;;
        --label)   label="$2"; shift 2 ;;
        --channel) channel="$2"; shift 2 ;;
        --thread)  thread="$2"; shift 2 ;;
        --log)     log="$2"; shift 2 ;;
        --)        shift; break ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ $# -gt 0 ] || { echo "usage: agent-job.sh [--label L] [--log F] -- <command>" >&2; exit 2; }
: "${channel:?pass --channel, or run where BUZZ_CHANNEL is set}"
: "${thread:?pass --thread, or run where BUZZ_THREAD is set}"

id="$(date +%s)-$$"
job="$JOBS/$id.job"
log="${log:-$JOBS/$id.log}"
: > "$log"

# The job gets its own session, not just nohup: a harness that kills its turn's whole
# process group takes a merely-nohup'd child with it, which was observed twice. macOS
# ships no setsid(1), so fall back to python3 - already a watcher dependency.
# Backgrounding the detacher directly, rather than a subshell around it, is what makes
# $! the pid that actually holds the job - which is what --check tests for liveness.
#
# The rc lands in its own file, never in the job file: the job file is written once and
# moved into place, and a child appending to it would race that move.
runner='log="$1"; rcf="$2"; shift 2; "$@" >"$log" 2>&1; printf "%s" "$?" > "$rcf"'
detach='import os, sys
try:
    os.setsid()
except OSError:
    pass          # already a group leader, so already out of the caller group
os.execvp(sys.argv[1], sys.argv[1:])'
if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$runner" _ "$log" "${job%.job}.rc" "$@" >/dev/null 2>&1 &
else
    python3 -c "$detach" bash -c "$runner" _ "$log" "${job%.job}.rc" "$@" >/dev/null 2>&1 &
fi

printf 'channel=%s\nthread=%s\nlabel=%s\nlog=%s\npid=%s\n' \
    "$channel" "$thread" "${label:-$1}" "$log" "$!" > "$job.tmp"
mv "$job.tmp" "$job"   # only now is it visible to --check, pid included

echo "started (pid $!): ${label:-$1}"
echo "log: $log"
echo "The thread gets a message when it ends. Do not wait on it - end the turn."
