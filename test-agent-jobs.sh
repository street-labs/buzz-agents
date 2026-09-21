#!/usr/bin/env bash
# Exercises agent-job.sh with a stub buzz: what it reports, and when it stays quiet.
# The case that matters is the last one - a job killed without a verdict, which is the
# only failure nothing else in the fleet catches. Run: bash test-agent-jobs.sh
set -u
JOB="$(cd "$(dirname "$0")" && pwd)/agent-job.sh"
T=$(mktemp -d)
export HOME="$T/home"
export AGENT_NAME=builder
export BUZZ_CHANNEL=chan1 BUZZ_THREAD=root1
JOBS="$HOME/.buzz/agents/builder/jobs"
mkdir -p "$HOME/.buzz/agents/builder"

# stand-in for the buzz CLI: records what would have been posted
# FAIL_MENTIONS=1 makes any send without an explicit --mention fail, like the
# relay does when an @token does not resolve to a channel member.
mkdir -p "$T/bin"
cat > "$T/bin/buzz" <<'INNER'
#!/bin/sh
if [ "$1" = reactions ]; then
    echo "reaction $2 $6" >> "$SENT"       # reactions add|remove --event <id> --emoji <e>
else
    shift 2                                # messages send
    mention=""; while [ $# -gt 0 ]; do
        case "$1" in
            --mention) mention="$2"; shift 2 ;;
            --content) shift; break ;;
            *) shift ;;
        esac
    done                                   # $1 is now the content
    if [ -n "$FAIL_MENTIONS" ] && [ -z "$mention" ]; then
        echo '{"error":"relay_error","message":"@builder does not match a current channel member"}'
        exit 2
    fi
    echo "$1" >> "$SENT"
fi
INNER
chmod +x "$T/bin/buzz"
export BUZZ="$T/bin/buzz" SENT="$T/sent.log"; : > "$SENT"

fail() { echo "FAIL: $1"; exit 1; }
posted() { grep -qF "$1" "$SENT"; }

# 1. a job still running is not reported, and does not lose its place
bash "$JOB" --label slow -- sleep 30 >/dev/null || fail "could not start a job"
posted "reaction add" || fail "no reaction marking the thread as waiting on a job"
bash "$JOB" --check
grep -qv reaction "$SENT" 2>/dev/null && grep -q 'finished\|stopped' "$SENT" && fail "reported a job that is still running"
[ "$(ls "$JOBS"/*.job 2>/dev/null | wc -l)" -eq 1 ] || fail "lost the running job's file"

# 2. a job that succeeds is reported with rc=0, once, then forgotten
bash "$JOB" --label green -- true >/dev/null
sleep 1
bash "$JOB" --check
posted 'job "green" finished rc=0' || fail "did not report a successful job"
bash "$JOB" --check
[ "$(grep -c 'green' "$SENT")" -eq 1 ] || fail "reported the same job twice"

# 3. a failing job carries its real exit code, not just failure
bash "$JOB" --label red -- sh -c 'exit 7' >/dev/null
sleep 1
bash "$JOB" --check
posted 'job "red" finished rc=7' || fail "did not carry the exit code through"

# 4. the whole point: a job killed without writing a verdict is still reported
bash "$JOB" --label doomed -- sleep 30 >/dev/null
doomed="$(grep -l 'label=doomed' "$JOBS"/*.job)"
kill -9 "$(sed -n 's/^pid=//p' "$doomed")" 2>/dev/null
sleep 1
bash "$JOB" --check
posted 'job "doomed" stopped without a verdict' || fail "a killed job went unreported"

# 5. the message @-mentions the agent, which is what re-summons it
grep -q '^@builder ' "$SENT" || fail "message does not summon the agent"

# 6. output goes to the log, not to the caller's context
bash "$JOB" --label noisy -- sh -c 'echo LOUD' >"$T/caller.out"
sleep 1
grep -q LOUD "$T/caller.out" && fail "job output leaked into the caller's output"
grep -qr LOUD "$JOBS" || fail "job output did not reach the log"

# 7. the job outlives a kill of the caller's whole process group. This is the failure
#    that prompted the script: a harness that tears down a turn takes a merely-nohup'd
#    child with it, and the build dies looking exactly like a build still running.
echo "  (the Terminated: 15 below is this case killing its own process group, on purpose)"
cat > "$T/launch.sh" <<INNER
bash "$JOB" --label orphan -- sleep 8 >/dev/null
sleep 1
sed -n 's/^pid=//p' "\$(grep -l 'label=orphan' "$JOBS"/*.job)" > "$T/orphan.pid"
kill -TERM -\$(ps -o pgid= -p \$\$ | tr -d '[:space:]')
INNER
( python3 -c 'import os,sys
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' bash "$T/launch.sh" ) >/dev/null 2>&1
sleep 1
kill -0 "$(cat "$T/orphan.pid" 2>/dev/null)" 2>/dev/null || fail "job died with the caller's process group"
pkill -f 'sleep 8' 2>/dev/null

# 8. the waiting reaction survives until the LAST job on the thread reports, so two
#    builds at once do not make the thread look idle after the first one lands
posted "reaction remove" && fail "cleared the waiting reaction while a job was still running"
pkill -f 'sleep 30' 2>/dev/null
sleep 1
bash "$JOB" --check
posted "reaction remove" || fail "never cleared the waiting reaction"
[ "$(ls "$JOBS"/*.job 2>/dev/null | wc -l)" -eq 0 ] || fail "left a job file behind"

# 9. an @token that does not resolve (profile-name drift, the keeper rename) must not
#    fail the post: the agent's own pubkey goes out as an explicit --mention, which the
#    relay treats as identity, making the @Name text presentation-only.
export FAIL_MENTIONS=1
bash "$JOB" --label renamed -- true >/dev/null
sleep 1
bash "$JOB" --check
posted 'job "renamed" finished rc=0' || fail "unresolvable @Name broke the outcome post"
[ "$(ls "$JOBS"/*.job 2>/dev/null | wc -l)" -eq 0 ] || fail "left a job file behind"

# 10. a send that stays broken retries with backoff, then gives up with a durable
#     record - it must not retry every poll cycle forever (keeper burned ~3h CPU).
unset FAIL_MENTIONS
cat > "$T/bin/buzz" <<'INNER'
#!/bin/sh
[ "$1" = messages ] && exit 2          # sends always fail; reactions still work
if [ "$1" = reactions ]; then echo "reaction $2 $6" >> "$SENT"; fi
exit 0
INNER
chmod +x "$T/bin/buzz"
export MAX_JOB_SEND_ATTEMPTS=3 JOB_BACKOFF_BASE=0
bash "$JOB" --label broken -- true >/dev/null
sleep 1
bash "$JOB" --check; bash "$JOB" --check; bash "$JOB" --check
[ -f "$JOBS/gave-up.log" ] && grep -q 'label=broken' "$JOBS/gave-up.log" || fail "no durable give-up record"
[ "$(ls "$JOBS"/*.job 2>/dev/null | wc -l)" -eq 0 ] || fail "gave-up job was not forgotten"
posted "reaction remove" || fail "never cleared the waiting reaction after giving up"

# 11. backoff actually defers: a failed check records a future retry window, and
#     later checks stay quiet until it passes
export MAX_JOB_SEND_ATTEMPTS=3 JOB_BACKOFF_BASE=9999
bash "$JOB" --label deferred -- true >/dev/null
sleep 1
bash "$JOB" --check
[ "$(ls "$JOBS"/*.job 2>/dev/null | wc -l)" -eq 1 ] || fail "lost the backed-off job"
posted 'job "deferred"' && fail "retried while backed off"
[ -n "$(sed -n 's/^next=//p' "$JOBS"/*.job)" ] || fail "failed check did not record a retry window"

 echo "PASS"; rm -rf "$T"
