#!/usr/bin/env bash
# Concurrent Buzz agent watcher (config-driven; one script, many agents).
#
# Spawns one worker per message (up to MAX_WORKERS, default 8) instead of processing
# sequentially, so a long-running task in one thread never blocks the others. Each
# worker gets an isolated per-thread worktree and resumes the harness session for that
# thread. Replies are posted back to the originating channel.
#
# What makes this a "full" agent (vs a one-shot):
#   - Per-thread session memory: the first message in a thread starts a session;
#     later messages in that thread resume it, so the agent remembers what it already
#     did (no amnesiac "I already added you" mistakes).
#   - Verify-before-claim + own-branch/PR guardrail come from the base system
#     prompt (setup/agents/base-agent-prompt.md), appended to every turn.
#
# Architecture:
#   - Main loop: polls channels for @mentions, spawns a worker per message
#   - Worker: isolated bash process handling one message (worktree + harness session)
#   - State: shared TSV files track sessions/worktrees, workers use flock for safety
#   - Cleanup: reaps finished workers, enforces the concurrency cap
#
# Usage: agent-watcher.sh /path/to/<name>.env      (or set AGENT_CONFIG=...)
# The .env is sourced and must define at least: AGENT_NAME, AGENT_KEY_FILE, AGENT_REPO.
set -uo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.claude/local:$HOME/.buzz/bin:/usr/bin:/bin:$PATH"

# launchd starts us with no locale, so Ruby and Python default to US-ASCII. Build
# tooling that pipes through Ruby dies on the first non-ASCII byte of compiler
# output — xcpretty raises "invalid byte sequence in US-ASCII", and because
# fastlane pipes xcodebuild through it under `set -o pipefail`, a build that
# compiled cleanly is reported as a failure. It never reproduces in a terminal,
# where the locale is already set.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# PPQ_API_KEY: pi's ppq provider reads it ONLY from the environment - it does NOT fall
# back to ~/.pi/agent/auth.json (a turn with no key returns an empty assistant message,
# which the bot then posts). Agents launched from a `tmux new-session`,
# which inherits the tmux server's environment - often WITHOUT PPQ_API_KEY when the
# server was (re)started from a non-login context (e.g. a relay/primary restart). So
# resolve the key from the macOS keychain here, self-healing regardless of launch env:
# the user's login keychain first, then the System keychain (auto-unlocked at boot,
# readable over SSH). Learned from a production
# empty-reply outage after a relay upgrade.
if [ -z "${PPQ_API_KEY:-}" ]; then
  PPQ_API_KEY="$(security find-generic-password -s buzz-agents-ppq -w 2>/dev/null || true)"
  [ -z "$PPQ_API_KEY" ] && PPQ_API_KEY="$(security find-generic-password -s buzz-agents-ppq -w /Library/Keychains/System.keychain 2>/dev/null || true)"
  export PPQ_API_KEY
fi

# Use 1h cache TTL (instead of default 5min ephemeral) so cache survives gaps between
# agent turns. Without this, multiple concurrent agents thrash the 5min cache, causing
# ~18% of calls to miss cache and pay full price (see 2026-07-18 token-efficiency work).
export PI_CACHE_RETENTION=long

CONFIG="${1:-${AGENT_CONFIG:-}}"
[ -z "$CONFIG" ] && { echo "usage: agent-watcher.sh <config.env>"; exit 2; }
[ -f "$CONFIG" ] || { echo "config not found: $CONFIG"; exit 2; }
# shellcheck disable=SC1090
. "$CONFIG"

# Load harness adapters
HARNESS_ADAPTERS="${HARNESS_ADAPTERS:-$HOME/.buzz/agents/harness-adapters.sh}"
[ -f "$HARNESS_ADAPTERS" ] && . "$HARNESS_ADAPTERS" || { echo "harness-adapters.sh not found: $HARNESS_ADAPTERS"; exit 2; }

# PPQ billing helpers: turn a silent 402 (drained balance) into a Buzz alert with a
# top-up invoice instead of a dark agent. Optional - fall back to no-ops if absent.
PPQ_BILLING="${PPQ_BILLING:-$HOME/.buzz/agents/ppq-billing.sh}"
[ -f "$PPQ_BILLING" ] && . "$PPQ_BILLING"
type ppq_output_is_402 >/dev/null 2>&1 || ppq_output_is_402() { return 1; }
type ppq_alert         >/dev/null 2>&1 || ppq_alert()         { return 0; }

: "${AGENT_NAME:?config must set AGENT_NAME}"
: "${AGENT_KEY_FILE:?config must set AGENT_KEY_FILE}"
: "${AGENT_REPO:?config must set AGENT_REPO}"

# Per-agent PPQ keys are for spend attribution. They are optional: agents without
# a buzz-agents-ppq-<agent> keychain item keep using the shared buzz-agents-ppq key resolved above.
if type ppq_agent_key >/dev/null 2>&1; then
  agent_ppq_key="$(ppq_agent_key "$AGENT_NAME" 2>/dev/null || true)"
  [ -n "$agent_ppq_key" ] && export PPQ_API_KEY="$agent_ppq_key"
fi

AGENT_HARNESS="${AGENT_HARNESS:-claude}"                # claude (default) | pi | goose
# No default model. A silent fallback to sonnet once drained the PPQ balance (2026-07-16);
# fail closed instead - the env must name the model so cost is always an explicit choice.
: "${AGENT_MODEL:?config must set AGENT_MODEL (no default - refusing to fall back to an expensive model)}"
# router-* profiles are a pi feature. Because AGENT_HARNESS defaults to claude, an env
# that sets a router model but forgets AGENT_HARNESS="pi" passes the name straight
# through to Claude Code, which rejects it on the first mention. Fail at startup
# instead.  (learned the hard way from a production outage).
case "$AGENT_MODEL:$AGENT_HARNESS" in
  router-*:pi) ;;
  router-*:*)
    echo "[${AGENT_NAME:-agent}] config error: AGENT_MODEL=\"$AGENT_MODEL\" is a pi router profile but AGENT_HARNESS=\"$AGENT_HARNESS\". Set AGENT_HARNESS=\"pi\"." >&2
    exit 2
    ;;
esac
# Same trap for codex model ids. Claude Code rejects an unknown model on the first mention,
# so without this the agent looks healthy at startup and dies on its first real message.
case "$AGENT_MODEL:$AGENT_HARNESS" in
  gpt-*:codex|codex*:codex) ;;
  gpt-*:*|codex-*:*)
    echo "[${AGENT_NAME:-agent}] config error: AGENT_MODEL=\"$AGENT_MODEL\" is an OpenAI/Codex model but AGENT_HARNESS=\"$AGENT_HARNESS\". Set AGENT_HARNESS=\"codex\"." >&2
    exit 2
    ;;
esac
AGENT_BASE_PROMPT_FILE="${AGENT_BASE_PROMPT_FILE:-$HOME/.buzz/agents/base-agent-prompt.md}"
AGENT_PERSONA_FILE="${AGENT_PERSONA_FILE:-}"
AGENT_GUARDRAIL="${AGENT_GUARDRAIL:-branch-pr}"
AGENT_CHANNELS="${AGENT_CHANNELS:-}"
AGENT_EXCLUDE_FILE="${AGENT_EXCLUDE_FILE:-}"
# HOME channels: where this agent is PRIMARY and follows threads normally (space/newline
# separated ids). If set, the agent is SUMMON-ONLY in every OTHER channel it watches -
# it answers a direct @mention there, then bows out. New channels are summon-only by
# default (they are not home), so no per-channel wiring is needed as channels grow.
AGENT_HOME_CHANNELS="${AGENT_HOME_CHANNELS:-}"
# Legacy explicit summon-only denylist (still honored). Prefer AGENT_HOME_CHANNELS.
AGENT_MENTION_ONLY_FILE="${AGENT_MENTION_ONLY_FILE:-}"
# Shared: pubkeys of "assist" agents that never claim the active-follow-up slot in
# ANY channel, so summoning one for one-off context does not silence the channel's
# own agent. Read by every watcher.
AGENT_ASSIST_FILE="${AGENT_ASSIST_FILE:-$HOME/.buzz/agents/assist.txt}"
AGENT_PEERS_FILE="${AGENT_PEERS_FILE:-$HOME/.buzz/agents/peers.txt}"
MODEL_TIMEOUT="${MODEL_TIMEOUT:-600}"
AMBIENT_COUNT="${AMBIENT_COUNT:-8}"
MAX_WORKERS="${MAX_WORKERS:-8}"  # max concurrent claude sessions
BOOT_GRACE="${BOOT_GRACE_SECONDS:-600}"  # on boot, only suppress history OLDER than this; recent unanswered mentions survive a restart

# The concurrent watcher serializes shared-state writes with flock, which macOS does
# not ship by default. Without it, workers write unlocked and can race/corrupt state.
command -v flock >/dev/null 2>&1 || echo "[$AGENT_NAME] WARNING: 'flock' not found - install it (brew install flock). Concurrent state writes will run UNLOCKED and may race." >&2

# Singleton: exactly one watcher per agent, enforced by the watcher itself (not just
# the launcher). a launcher's pgrep guard once raced in production (four duplicate watchers
# spawned in one second; quadruple replies to every mention), and manual launches in
# tmux bypass the launcher entirely. flock is NOT usable here: homebrew flock 0.4.0
# on macOS does not enforce `flock -n <fd>` exclusion (see note above), so we use an
# atomic mkdir mutex with PID-liveness for stale-lock recovery. A second instance
# exits immediately instead of double-replying.
_single_dir="${AGENTS_DIR:-$HOME/.buzz/agents}/$AGENT_NAME/.watcher.lock"
_single_try() { mkdir "$_single_dir" 2>/dev/null && { echo $$ > "$_single_dir/pid"; return 0; }; return 1; }
if ! _single_try; then
  _single_pid=$(cat "$_single_dir/pid" 2>/dev/null || true)
  if [ -n "$_single_pid" ] && kill -0 "$_single_pid" 2>/dev/null; then
    echo "[$AGENT_NAME] watcher already running (pid $_single_pid) - refusing to start a duplicate" >&2
    exit 0
  fi
  # Stale lock from a crashed/killed watcher - reclaim once. If we lose the reclaim
  # race to a peer, bow out; it is the live one.
  rm -rf "$_single_dir"
  if ! _single_try; then
    echo "[$AGENT_NAME] lost stale-lock reclaim race - refusing to start a duplicate" >&2
    exit 0
  fi
fi
trap 'rm -rf "$_single_dir"' EXIT

unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
export BUZZ_RELAY_URL="${BUZZ_RELAY_URL:-http://localhost:3000}"
export BUZZ_PRIVATE_KEY="$(cat "$AGENT_KEY_FILE")"
BUZZ="$(command -v buzz || echo "$HOME/.buzz/bin/buzz")"
export OWNER="${OWNER:?Set OWNER to the human owner hex pubkey (nak key public <your-nsec>)}"  # agents add this key on channel create
BOT_PUB="$(nak key public "$(cat "$AGENT_KEY_FILE")" 2>/dev/null)"

STATE="$HOME/.buzz/agents/$AGENT_NAME"; mkdir -p "$STATE"

# Singleton guard: one watcher per agent. A second copy (duplicate tmux session,
# relaunch before the old one died) takes the lock non-blocking and exits instead
# of double-handling messages. flock(2) is released automatically when the holder
# dies, so a crashed watcher never wedges the lock.
exec 9>"$STATE/watcher.lock"
if ! flock -n 9; then
  echo "[$AGENT_NAME] another watcher already holds $STATE/watcher.lock - exiting" >&2
  exit 0
fi

SEEN="$STATE/seen.txt"; touch "$SEEN"
THREADS="$STATE/threads.txt"; touch "$THREADS"
SESSIONS="$STATE/sessions.tsv"; touch "$SESSIONS"
WORKTREES="$STATE/worktrees.tsv"; touch "$WORKTREES"
WORKERS="$STATE/workers"; mkdir -p "$WORKERS"  # worker pid files: $WORKERS/<msg_id>.pid
COSTS="$STATE/costs.tsv"; touch "$COSTS"        # root_id \t cumulative_cost_usd \t cumulative_tokens
LASTTURN="$STATE/lastturn.tsv"; touch "$LASTTURN"  # root_id \t created_at of last answered msg (delta-context key)
FRESHNEXT="$STATE/freshnext.txt"; touch "$FRESHNEXT"  # roots whose next turn starts a fresh harness session
CARRY="$STATE/carry"; mkdir -p "$CARRY"        # per-root compaction summaries seeded into the next turn
LIMITED="$STATE/limited-until"                  # epoch until which the primary harness is rate-limited
# name<TAB>id map of channels this bot can read, for cross-channel references
# (#name or buzz:// links). Inherited by the Claude subprocess via the env.
export BUZZ_CHANNELS_TSV="$STATE/channels.tsv"; touch "$BUZZ_CHANNELS_TSV"

# System prompt (same as sequential version)
case "$AGENT_GUARDRAIL" in
  direct-main)
    GUARDRAIL="## Git workflow (this OVERRIDES any default 'if on the default branch, branch first' guidance)
You are the \"$AGENT_NAME\" agent working in the ops-brain repo. This repo is
single-writer and uses direct-to-main: commit your work directly to \`main\` and push
to origin/main frequently, and pull to stay in sync. Do NOT create a branch and do
NOT open a PR - that default does not apply here. Verify each push landed
(git log origin/main) before claiming it did.
You are the ops-brain. When you are pulled into a PROJECT channel, answer the
ops/business question that was asked and nothing more - do NOT implement, build, run,
or commit that project's code, and never touch its repo. The project's own agent owns
all of that. If the ask is really project implementation, say so and hand off." ;;
  *)
    GUARDRAIL="## Git guardrail: your own branch, never main
You are the \"$AGENT_NAME\" agent. Work on a branch, never \`main\`. Your worktree starts
on \`agent/$AGENT_NAME-<id>\`, but if the repo documents a branch naming convention
(CLAUDE.md, AGENTS.md, CONTRIBUTING) that convention wins - rename to it with
\`git branch -m <name>\` before your first push. The watcher tracks whichever branch the
worktree is actually on, so renaming is safe.
Commit there and push it (SSH push works headlessly). When a unit of work is ready,
open a PR with \`gh pr create\` for a human to merge - never merge to \`main\` yourself.
If \`gh\` is not authed, push the branch and report the branch name + a PR summary." ;;
esac
SYSTEM_PROMPT="$(cat "$AGENT_BASE_PROMPT_FILE" 2>/dev/null)

$GUARDRAIL"
[ -n "$AGENT_PERSONA_FILE" ] && [ -f "$AGENT_PERSONA_FILE" ] && \
  SYSTEM_PROMPT="${SYSTEM_PROMPT}

$(cat "$AGENT_PERSONA_FILE")"

# Multi-agent awareness: name the other agents so this one does not treat messages
# aimed at them (or at the room in general) as its own instructions.
AGENT_ROSTER_FILE="${AGENT_ROSTER_FILE:-$HOME/.buzz/agents/roster.tsv}"  # pubkey<TAB>name
OTHER_AGENTS="$(awk -F'\t' -v me="$AGENT_NAME" 'NF>=2 && $2!=me{printf "%s%s",(n++?", ":""),$2} END{print ""}' "$AGENT_ROSTER_FILE" 2>/dev/null)"
SYSTEM_PROMPT="${SYSTEM_PROMPT}

## Shared workspace - not every message is for you
You are the \"$AGENT_NAME\" agent. Other agents share these same channels and threads${OTHER_AGENTS:+ (currently: $OTHER_AGENTS)}. the owner talks to all of you here. A message that @-mentions or is clearly aimed at a DIFFERENT agent is NOT an instruction for you - it is background context so you can follow the conversation. Act only on messages addressed to you by name, or ones unmistakably meant for everyone. When a message looks aimed at another agent, do not act on it and do not answer on their behalf. The thread history is labelled with who said what and, for the owner's messages, who they were directed to."

# --- FILTER: new owner messages worth answering; resolve thread root ---
# Acts when the message directly addresses this agent (@name in text, or a p-tag to
# our pubkey) OR is in a thread we already track. While merely FOLLOWING a thread we
# were pulled into, only the thread OWNER keeps it going; guests defer. Output adds a
# trailing `directly` flag. (Kept identical to the sequential agent-watcher.sh.)
FILTER='
import sys, json, base64
seen = set(open(sys.argv[1]).read().split())
owner = sys.argv[2]
name = sys.argv[3].lower()
threads = {}   # root_id -> role ("owner" starts the thread; "guest" was pulled in)
try:
    for line in open(sys.argv[4]):
        p = line.split()
        if p:
            threads[p[0]] = p[1] if len(p) > 1 else "owner"
except:
    threads = {}
try:
    peers = set(open(sys.argv[5]).read().split())
except:
    peers = set()
me = sys.argv[6] if len(sys.argv) > 6 else ""
# mention_only: in this channel we answer ONLY a direct address and never auto-follow
# untagged thread activity (summon-then-bow-out). assist: agent pubkeys that never
# claim the "active" slot, so summoning one does not silence the channel agent.
mention_only = (len(sys.argv) > 7 and sys.argv[7] == "1")
assist = set()
try:
    if len(sys.argv) > 8 and sys.argv[8]:
        assist = set(open(sys.argv[8]).read().split())
except:
    assist = set()
try:
    msgs = json.load(sys.stdin)
except:
    msgs = []
by_id = {m.get("id", ""): m for m in msgs}

def find_root(m, depth=0):
    if depth > 5:
        return (m.get("id", ""), True)
    root_id = None; reply_to = None
    for tag in m.get("tags", []):
        if len(tag) >= 2 and tag[0] == "e":
            marker = tag[3] if len(tag) > 3 else ""
            if marker == "root": root_id = tag[1]
            elif marker == "reply": reply_to = tag[1]
            elif not marker and reply_to is None: reply_to = tag[1]
    if root_id: return (root_id, True)
    if reply_to:
        parent = by_id.get(reply_to)
        if parent:
            pr, _ = find_root(parent, depth + 1); return (pr, True)
        return (reply_to, True)
    return (m.get("id", ""), False)

for m in msgs:
    mid = m.get("id", ""); pub = m.get("pubkey", ""); c = (m.get("content", "") or "")
    if mid in seen:
        continue
    ptags = [t[1] for t in m.get("tags", []) if len(t) >= 2 and t[0] == "p"]
    peer_ptags = [p for p in ptags if p in peers]
    # Multi-summon (2+ agents p-tagged) is allowed: each watcher independently
    # sees its own p-tag below (`explicitly`) and answers once. A former blanket
    # skip here meant tagging two bots summoned NEITHER.
    root_id, threaded = find_root(m)
    cl = c.lower()
    # explicitly = a DELIBERATE summon: a p-tag to us or a literal "@name". directly
    # also honors a bare name mention and the generic @builder/@agent (looser, for
    # normal channels where the agent follows along).
    explicitly = (me and me in ptags) or (("@" + name) in cl)
    directly = explicitly or (name in cl) or ("@builder" in cl) or ("@agent" in cl)
    # Allow owner messages always, OR peer messages that explicitly summon us (bot-to-bot coordination).
    if pub != owner:
        if pub not in peers or not explicitly:
            continue
    in_thread = threaded and root_id in threads
    if mention_only:
        # Summon-only channel: act ONLY on a deliberate @mention / p-tag, then bow out.
        # A bare mention of the name (third person) or a generic @builder/@agent aimed
        # at the channel own agent does NOT summon us.
        if not explicitly:
            continue
    else:
        if not directly and not in_thread:
            continue
        if in_thread and not directly:
            # Defer if this message explicitly p-tags a different agent.
            if any(p != me for p in peer_ptags):
                continue
            # Otherwise only the "active" agent answers an untagged follow-up: the peer
            # the owner most recently addressed in this thread. Someone else -> stand
            # down; me (or nobody was ever addressed here) -> answer. Assist agents
            # (e.g. an ops agent summoned for one-off context) never count as "active", so
            # summoning one does not hand it the thread or silence the channel agent.
            mt = m.get("created_at", 0); active = None; active_t = -1
            for x in msgs:
                if x.get("pubkey") != owner or x.get("created_at", 0) > mt:
                    continue
                if find_root(x)[0] != root_id:
                    continue
                xp = [p for p in (t[1] for t in x.get("tags", []) if len(t) >= 2 and t[0] == "p") if p in peers and p not in assist]
                if len(xp) == 1 and x.get("created_at", 0) > active_t:
                    active_t = x.get("created_at", 0); active = xp[0]
            if active is not None and active != me:
                continue
    print(mid + "\t" + base64.b64encode(c.encode()).decode() + "\t" + root_id + "\t" + str(int(threaded)) + "\t" + str(int(bool(directly))))
'

FORMAT_CONTEXT='
import sys, json
owner = sys.argv[1]; me = sys.argv[2]; myname = sys.argv[3]
roster = {}
try:
    for line in open(sys.argv[4]):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2: roster[parts[0]] = parts[1]
except: pass
def name_of(pub):
    if pub == owner: return "the owner"
    if pub == me: return myname
    return roster.get(pub, pub[:8])
def who_line(m):
    pub = m.get("pubkey",""); w = name_of(pub)
    to = [roster[t[1]] for t in m.get("tags", []) if len(t) >= 2 and t[0] == "p" and t[1] in roster]
    if to:
        if pub == owner:
            w = "the owner -> " + ", ".join(to)
        else:
            w = w + " -> " + ", ".join(to)
    return w
def fmt(msgs, skip=None):
    skip = skip or set(); out = []
    for m in msgs:
        if m.get("id","") in skip: continue
        c = (m.get("content","") or "")
        if not c.strip(): continue
        out.append("[" + who_line(m) + "] " + c)
    return out
lines = sys.stdin.read().strip().split("\n")
thread_msgs = json.loads(lines[0]) if len(lines) > 0 and lines[0] else []
recent_msgs = json.loads(lines[1]) if len(lines) > 1 and lines[1] else []
current = json.loads(lines[2]) if len(lines) > 2 and lines[2] else {}
cid = current.get("id",""); parts = []
since = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] else 0
if thread_msgs:
    if since > 0:
        # Resumed session: only messages that arrived AFTER the last turn we answered.
        # The session already holds prior conversation history; re-sending it bloats
        # context (cost + latency + accuracy drag). File/session state carries the rest.
        thread_msgs = [m for m in thread_msgs if m.get("created_at", 0) > since]
    tl = fmt(thread_msgs, {cid})
    if tl: parts.append(("## New messages since your last turn\n" if since > 0 else "## Thread history (oldest first)\n") + "\n\n".join(tl))
tids = {m.get("id","") for m in thread_msgs}
if since == 0:
    # Ambient room context only on the FIRST turn of a thread. On resume the session
    # has context, and cross-thread ambient caused context bleed (decision 2026-07-13).
    rl = fmt(recent_msgs, tids | {cid})
    if rl: parts.append("## Recent channel messages (ambient)\n" + "\n\n".join(rl))
parts.append("## Current message from " + who_line(current) + "\n" + (current.get("content","") or ""))
print("\n\n".join(parts))
'

extract_field() {
  python3 -c '
import sys, json
s = open(sys.argv[1]).read(); i = s.find("{");
try:
    print(json.loads(s[i:]).get(sys.argv[2], "") or "")
except: print("")
' "$1" "$2"
}

get_msg_by_id() {
  printf '%s' "$2" | python3 -c "
import sys, json
t = sys.argv[1]
try:
    for m in json.load(sys.stdin):
        if m.get('id') == t: print(json.dumps(m)); break
except: pass
" "$1"
}

list_channel_ids() {
  if [ -n "$AGENT_CHANNELS" ]; then
    printf '%s\n' $AGENT_CHANNELS
    return
  fi
  "$BUZZ" channels list 2>/dev/null | python3 -c '
import sys, json
excl = set()
if len(sys.argv) > 1:
    try: excl = set(open(sys.argv[1]).read().split())
    except: pass
try:
    for c in json.load(sys.stdin):
        cid = c.get("channel_id") or c.get("id")
        if cid and cid not in excl: print(cid)
except: pass' "$AGENT_EXCLUDE_FILE"
}

# Is this channel summon-only for this agent (answer direct @mentions, bow out of
# untagged follow-ups)? True when AGENT_HOME_CHANNELS is set and this channel is NOT in
# it (the agent is a guest here), OR the channel is in the legacy AGENT_MENTION_ONLY_FILE.
is_summon_only() {  # $1=channel id
  if [ -n "$AGENT_HOME_CHANNELS" ]; then
    case " $(printf '%s' "$AGENT_HOME_CHANNELS" | tr '\n' ' ') " in
      *" $1 "*) : ;;              # home channel -> primary, follow threads
      *) return 0 ;;              # not home -> summon-only
    esac
  fi
  [ -n "$AGENT_MENTION_ONLY_FILE" ] && [ -f "$AGENT_MENTION_ONLY_FILE" ] || return 1
  grep -v '^#' "$AGENT_MENTION_ONLY_FILE" 2>/dev/null | tr -d '[:blank:]' | grep -qxF "$1"
}

write_channel_map() {  # refresh name<TAB>id map of channels this bot can read
  "$BUZZ" channels list 2>/dev/null | python3 -c '
import sys, json
try:
    rows = []
    for c in json.load(sys.stdin):
        cid = c.get("channel_id") or c.get("id"); nm = c.get("name") or c.get("slug") or ""
        if cid: rows.append((nm, cid))
    sys.stdout.write("".join(f"{n}\t{i}\n" for n, i in rows))
except: pass' > "$BUZZ_CHANNELS_TSV.tmp" 2>/dev/null && mv "$BUZZ_CHANNELS_TSV.tmp" "$BUZZ_CHANNELS_TSV" 2>/dev/null || true
}

# Thread-safe TSV accessors using flock
get_session() {
  flock "$SESSIONS" awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$SESSIONS"
}

set_session() {
  local tmp; tmp="$(mktemp)"
  (
    flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$SESSIONS" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mv "$tmp" "$SESSIONS"
  ) 200>"$SESSIONS.lock"
}

get_worktree() {
  flock "$WORKTREES" awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$WORKTREES"
}

get_worktree_branch() {
  flock "$WORKTREES" awk -F'\t' -v r="$1" '$1==r{print $3; exit}' "$WORKTREES"
}

set_worktree() {
  local tmp; tmp="$(mktemp)"
  (
    flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$WORKTREES" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
    mv "$tmp" "$WORKTREES"
  ) 200>"$WORKTREES.lock"
}

# Cost tracking (thread-safe; workers run concurrently so flock every read/write).
get_cost() {
  flock "$COSTS" awk -F'\t' -v r="$1" '$1==r{print $2":"$3; exit}' "$COSTS"
}
add_cost() {  # $1=root $2=cost_usd $3=tokens
  local root="$1" new_cost="$2" new_tokens="$3"
  local prev; prev="$(get_cost "$root")"
  local prev_cost="0.0" prev_tokens="0"
  if [ -n "$prev" ]; then prev_cost="${prev%%:*}"; prev_tokens="${prev##*:}"; fi
  local total_cost total_tokens
  total_cost="$(python3 -c "print($prev_cost + $new_cost)" 2>/dev/null || echo "$new_cost")"
  total_tokens="$(( prev_tokens + new_tokens ))"
  local tmp; tmp="$(mktemp)"
  (
    flock 200
    awk -F'\t' -v r="$root" '$1!=r' "$COSTS" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$root" "$total_cost" "$total_tokens" >> "$tmp"
    mv "$tmp" "$COSTS"
  ) 200>"$COSTS.lock"
  echo "$total_cost:$total_tokens"
}

# Last-turn tracking (thread-safe): created_at of the last message we answered in a
# thread. On resume, only messages newer than this are sent to the harness.
get_lastturn() {
  flock "$LASTTURN" awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$LASTTURN"
}
set_lastturn() {  # $1=root $2=ts
  local tmp; tmp="$(mktemp)"
  (
    flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$LASTTURN" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mv "$tmp" "$LASTTURN"
  ) 200>"$LASTTURN.lock"
}

# Drop the harness session and delta-context watermark for a thread. The worktree
# stays intact; durable state should already be on disk there.
reset_thread_session() {  # $1=root
  local tmp_s tmp_l
  tmp_s="$(mktemp)"; tmp_l="$(mktemp)"
  (
    flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$SESSIONS" > "$tmp_s" 2>/dev/null || true
    mv "$tmp_s" "$SESSIONS"
  ) 200>"$SESSIONS.lock"
  (
    flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$LASTTURN" > "$tmp_l" 2>/dev/null || true
    mv "$tmp_l" "$LASTTURN"
  ) 200>"$LASTTURN.lock"
}

# --- Primary-harness session limit -------------------------------------------------
#
# Claude Code does not error on a usage limit; it returns the limit notice as the turn
# RESULT, so it sails through as a normal reply and gets posted to the channel. Builder did
# exactly that twice on 2026-08-31:
#
#   You've hit your session limit · resets 3:10pm (America/Indianapolis)
#
# The notice carries a reset time, so the switch back needs no polling and no timer - just
# compare the clock on the next turn.
LIMIT_RE="hit your session limit"

# Print the epoch the limit resets at, or nothing if the reply is not a limit notice.
session_limit_until() {  # $1=reply text
  printf '%s' "$1" | python3 -c '
import sys, re, datetime
try: from zoneinfo import ZoneInfo
except ImportError: sys.exit(0)
t = sys.stdin.read()
if "hit your session limit" not in t: sys.exit(0)
m = re.search(r"resets\s+(\d{1,2}):(\d{2})\s*([ap]m)\s*\(([^)]+)\)", t, re.I)
if not m: sys.exit(0)
h, mi, ampm, tz = int(m.group(1)), int(m.group(2)), m.group(3).lower(), m.group(4)
if ampm == "pm" and h != 12: h += 12
if ampm == "am" and h == 12: h = 0
try: z = ZoneInfo(tz)
except Exception: sys.exit(0)
now = datetime.datetime.now(z)
r = now.replace(hour=h, minute=mi, second=0, microsecond=0)
# A reset time already past today means it is tomorrow.
if r <= now: r += datetime.timedelta(days=1)
print(int(r.timestamp()))
' 2>/dev/null
}

primary_is_limited() {
  local until; until="$(cat "$LIMITED" 2>/dev/null)"
  [ -n "$until" ] || return 1
  [ "$(date +%s)" -lt "$until" ] || { rm -f "$LIMITED"; return 1; }
}

# The fallback harness cannot resume the primary's session, so carry the conversation over
# by hand. Claude Code writes every turn to ~/.claude/projects/<path-slug>/<sid>.jsonl;
# the last handful of exchanges is ~1k tokens, small enough to prepend directly. This is
# mechanical on purpose - you cannot ask the limited harness to summarise itself.
bridge_from_transcript() {  # $1=session_id $2=work_dir
  python3 -c '
import sys, json, pathlib, re
sid, wd = sys.argv[1], sys.argv[2]
# Claude Code slugs the path by replacing every non-alphanumeric run with a dash, so
# /Users/luke.street/... becomes -Users-luke-street-... . Replacing only "/" silently
# misses the directory and the bridge comes back empty.
slug = re.sub(r"[^A-Za-z0-9]", "-", wd)
f = pathlib.Path.home() / ".claude" / "projects" / slug / f"{sid}.jsonl"
if not f.exists(): sys.exit(0)
rows = []
for line in f.open():
    try: d = json.loads(line)
    except Exception: continue
    if d.get("type") not in ("user", "assistant"): continue
    c = (d.get("message") or {}).get("content")
    if isinstance(c, list):
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    if isinstance(c, str) and c.strip():
        rows.append((d["type"], c.strip()))
if not rows: sys.exit(0)
print("Carried over from the previous session (the primary harness hit its usage limit):\n")
for role, text in rows[-20:]:
    print(f"{role}: {text[:1500]}\n")
' "$1" "$2" 2>/dev/null
}

# Harness-agnostic compaction. Only pi exposes a native compact call; claude, codex and
# cursor do not. But compaction is just "summarise, then start clean", and both halves
# already exist here: invoke_harness can run a summary turn in the live session, and the
# /fresh machinery already knows how to start the next turn clean. So the fallback is one
# implementation that works for every harness rather than four adapters that mostly cannot
# be written.
#
# Costs one model turn, unlike pi's RPC compaction. That is the price of generality.
# $1=root $2=sid $3=harness_model $4=work_dir $5=focus
generic_compact() {
  local root="$1" sid="$2" hmodel="$3" wdir="$4" focus="$5"
  local out summary pid wpid ask
  out="$(mktemp)"
  ask="Write a handoff summary of this session so a fresh session can continue the work without re-reading the thread.

Cover: what was decided and why, the current state of the work, exact file paths touched, any command that fails and how it fails, and every open loop.
${focus:+Preserve above all else: $focus}

Output only the summary. No preamble, no sign-off, and do not post anything to Buzz."

  invoke_harness "$AGENT_HARNESS" "$out" "$ask" "$hmodel" "$sid" "$wdir" "$SYSTEM_PROMPT" &
  pid=$!
  ( sleep "$MODEL_TIMEOUT"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) &
  wpid=$!
  wait "$pid" 2>/dev/null
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null

  summary="$(extract_harness_field "$AGENT_HARNESS" "$out" result)"
  rm -f "$out"
  if [ -z "$summary" ] || [ "$summary" = "null" ]; then
    printf 'error\t0\t0\tthe summary turn produced no output; session left unchanged\n'
    return 1
  fi

  printf '%s\n' "$summary" > "$CARRY/$root.md"
  reset_thread_session "$root"
  mark_fresh_next "$root"
  printf 'ok-seeded\t0\t%s\tsummarised into a carry-over seed\n' "$(( $(printf '%s' "$summary" | wc -c | tr -d ' ') / 4 ))"
}

# Try the harness's own compaction, fall back to the generic path when it has none.
# $1=harness $2=root $3=sid $4=harness_model $5=work_dir $6=focus
compact_session_any() {
  local result
  result="$(compact_harness_session "$1" "$3" "$4" "$5" "$6")"
  case "$(printf '%s' "$result" | cut -f4-)" in
    *"not supported"*) generic_compact "$2" "$3" "$4" "$5" "$6" ;;
    *) printf '%s\n' "$result" ;;
  esac
}

mark_fresh_next() {  # $1=root
  local tmp; tmp="$(mktemp)"
  (
    flock 200
    grep -v "^$1$" "$FRESHNEXT" > "$tmp" 2>/dev/null || true
    printf '%s\n' "$1" >> "$tmp"
    mv "$tmp" "$FRESHNEXT"
  ) 200>"$FRESHNEXT.lock"
}

consume_fresh_next() {  # $1=root; returns 0 and clears when marked
  local tmp found_file found
  tmp="$(mktemp)"; found_file="$(mktemp)"
  (
    flock 200
    if grep -qxF "$1" "$FRESHNEXT" 2>/dev/null; then
      grep -v "^$1$" "$FRESHNEXT" > "$tmp" 2>/dev/null || true
      mv "$tmp" "$FRESHNEXT"
      echo 0 > "$found_file"
    else
      echo 1 > "$found_file"
    fi
  ) 200>"$FRESHNEXT.lock"
  found="$(cat "$found_file" 2>/dev/null || echo 1)"
  rm -f "$found_file" "$tmp"
  [ "$found" = 0 ]
}

# A worktree path that no live thread claims, or empty if there is none.
#
# Slots are recycled rather than deleted because a worktree's path is what makes
# a build incremental: Xcode keys DerivedData on absolute source paths, and npm
# and CocoaPods install into the tree itself. A fresh path throws all of that
# away, which on a large iOS repo is a 40 minute cold build and several GB, every
# thread. Reusing the path keeps node_modules, Pods and DerivedData warm.
#
# Reclaim happens in two tiers, because refusing outright to touch a slot holding
# unpushed work would leak slots forever: most threads never open a PR, so their
# slot is never released by cleanup_worktree and would sit poisoned for good.
#
#   fresh  - clean, everything pushed. Reclaim and drop the old branch.
#   stale  - untouched for SLOT_STALE_DAYS. Reclaim, but first commit anything
#            uncommitted and keep the branch, so the work survives in the repo as
#            a ref even though the path is reused. Nothing is ever deleted, it
#            just stops occupying a slot.
#
# A slot the current thread list still claims is never touched at either tier.
SLOT_STALE_DAYS="${SLOT_STALE_DAYS:-3}"

slot_is_stale() {
  # No file modified inside the window. -mtime, not -newermt: find here may be
  # bfs, which rejects relative timestamps and would exit non-zero, and an
  # erroring find prints nothing, which reads as "stale" - the unsafe direction.
  local slot="$1" recent
  recent="$(find "$slot" -type f -mtime "-${SLOT_STALE_DAYS}" -not -path '*/.git/*' -print 2>/dev/null | head -1)"
  [ -z "$recent" ]
}

claim_free_slot() {
  local base_dir="$1" slot stale_candidate=""
  for slot in "$base_dir/$AGENT_NAME-slot-"*; do
    [ -d "$slot" ] || continue
    flock "$WORKTREES" grep -qF "	$slot	" "$WORKTREES" && continue

    if [ -z "$(git -C "$slot" status --porcelain 2>/dev/null)" ] &&
       [ -z "$(git -C "$slot" log --oneline HEAD --not --remotes 2>/dev/null)" ]; then
      echo "$slot"
      return 0
    fi

    # Holds work. Usable only once it has gone quiet, and preferred least.
    [ -z "$stale_candidate" ] && slot_is_stale "$slot" && stale_candidate="$slot"
  done

  [ -n "$stale_candidate" ] || return 1

  # Park uncommitted work on the branch so reusing the path cannot lose it.
  if [ -n "$(git -C "$stale_candidate" status --porcelain 2>/dev/null)" ]; then
    git -C "$stale_candidate" add -A >/dev/null 2>&1 || true
    git -C "$stale_candidate" commit -qm \
      "WIP: parked by watcher before reclaiming slot after ${SLOT_STALE_DAYS}d idle" >/dev/null 2>&1 || true
  fi
  echo "[$AGENT_NAME] reclaiming stale slot $stale_candidate (work kept on $(git -C "$stale_candidate" branch --show-current 2>/dev/null))" >&2
  echo "$stale_candidate"
}

create_worktree() {
  local root="$1" repo_name base_dir wt_path branch short_id existing old_branch n
  repo_name="$(basename "$AGENT_REPO")"
  base_dir="$(dirname "$AGENT_REPO")/${repo_name}-worktrees"
  mkdir -p "$base_dir"
  short_id="${root:0:8}"
  branch="agent/$AGENT_NAME-$short_id"

  # This thread already has one (including pre-slot worktrees named by root id).
  existing="$(get_worktree "$root")"
  [ -n "$existing" ] && [ -d "$existing" ] && { echo "$existing"; return 0; }
  [ -d "$base_dir/$short_id" ] && { echo "$base_dir/$short_id"; return 0; }

  if wt_path="$(claim_free_slot "$base_dir")"; then
    old_branch="$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")"
    # -fd without -x: drops stray tracked-adjacent files but keeps ignored build
    # output, which is the entire point of recycling the slot.
    ( cd "$AGENT_REPO" && git fetch origin >/dev/null 2>&1 ) || true
    if ! ( git -C "$wt_path" checkout -B "$branch" origin/main >/dev/null 2>&1 && \
           git -C "$wt_path" reset --hard origin/main >/dev/null 2>&1 && \
           git -C "$wt_path" clean -fd >/dev/null 2>&1 ); then
      echo "[$AGENT_NAME] slot reset failed for $wt_path, cutting a new one" >&2
      wt_path=""
    else
      # Only drop the old branch if it holds nothing a remote does not already
      # have. A reclaimed stale slot keeps its branch so the work stays findable.
      if [ -n "$old_branch" ] && [ "$old_branch" != "$branch" ] &&
         [ -z "$(git -C "$wt_path" log --oneline "$old_branch" --not --remotes 2>/dev/null)" ]; then
        ( cd "$AGENT_REPO" && git branch -D "$old_branch" >/dev/null 2>&1 ) || true
      fi
      echo "[$AGENT_NAME] recycled slot: $wt_path (branch $branch)" >&2
    fi
  else
    wt_path=""
  fi

  # No free slot, or the reset failed. Cut a new slot rather than block: running
  # out of slots must never stop a new thread from starting work.
  if [ -z "$wt_path" ]; then
    n=0
    while [ -e "$base_dir/$AGENT_NAME-slot-$n" ]; do n=$((n + 1)); done
    wt_path="$base_dir/$AGENT_NAME-slot-$n"
    ( cd "$AGENT_REPO" && git fetch origin >/dev/null 2>&1 && \
      git worktree add "$wt_path" -b "$branch" origin/main >/dev/null 2>&1 ) || {
      echo "[$AGENT_NAME] worktree creation failed for $root" >&2
      echo "$AGENT_REPO"
      return 1
    }
    echo "[$AGENT_NAME] created worktree: $wt_path (branch $branch)" >&2  # log to stderr; stdout is the captured path
  fi

  # Initialize submodules (if the repo has any) so hooks and scripts are present;
  # git worktree add does not auto-init submodules.
  git -C "$wt_path" submodule update --init --recursive >/dev/null 2>&1 || true

  set_worktree "$root" "$wt_path" "$branch"
  echo "$wt_path"
}

# Cleanup worktree if its PR merged/closed. Robust to agents that rename their
# branch: checks PR state on BOTH the watcher-assigned branch AND the branch the
# worktree is actually on (HEAD). If either is merged/closed, tear down the worktree
# and delete both branches. Without this, an agent that PRs from a custom-named
# branch leaves the worktree forever (the assigned-branch PR check finds nothing).
# $1=root_id
cleanup_worktree() {
  local root="$1" wt_path branch actual pr_state pr_state_actual
  wt_path="$(get_worktree "$root")"
  branch="$(get_worktree_branch "$root")"
  [ -z "$wt_path" ] && return 0
  [ ! -d "$wt_path" ] && return 0

  pr_state="$(cd "$wt_path" && gh pr view "$branch" --json state -q .state 2>/dev/null || echo "")"
  # The agent may have abandoned the assigned branch and PR'd from a custom-named
  # one (one agent of ours accumulated 45 stale worktrees). Check the branch the worktree
  # is actually on now.
  actual="$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")"
  pr_state_actual=""
  if [ -n "$actual" ] && [ "$actual" != "$branch" ]; then
    pr_state_actual="$(cd "$wt_path" && gh pr view "$actual" --json state -q .state 2>/dev/null || echo "")"
  fi

  if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ] || [ "$pr_state_actual" = "MERGED" ] || [ "$pr_state_actual" = "CLOSED" ]; then
    echo "[$AGENT_NAME] cleaning up worktree $wt_path (assigned=$branch:${pr_state:-none}${actual:+ actual=$actual:${pr_state_actual:-none}})"
    # Slots are released, not deleted: dropping the tsv row makes the path
    # claimable by the next thread with its build output still warm. Only the
    # older root-id-named worktrees are actually removed.
    case "$(basename "$wt_path")" in
      *-slot-*)
        # Back to origin/main, not HEAD: the PR is merged or closed either way, and
        # leaving the branch's commits in place would make the slot look like it
        # holds unpushed work once the remote branch is pruned, so it would never
        # be reclaimed.
        git -C "$wt_path" reset --hard origin/main >/dev/null 2>&1 || true
        git -C "$wt_path" clean -fd >/dev/null 2>&1 || true
        ;;
      *)
        ( cd "$AGENT_REPO" && git worktree remove "$wt_path" --force >/dev/null 2>&1 )
        ;;
    esac
    ( cd "$AGENT_REPO" && git branch -D "$branch" >/dev/null 2>&1 )
    [ -n "$actual" ] && [ "$actual" != "$branch" ] && ( cd "$AGENT_REPO" && git branch -D "$actual" >/dev/null 2>&1 )
    local tmp; tmp="$(mktemp)"
    (
      flock 200
      awk -F'\t' -v r="$root" '$1!=r' "$WORKTREES" > "$tmp" 2>/dev/null || true
      mv "$tmp" "$WORKTREES"
    ) 200>"$WORKTREES.lock"
  fi
}

# Boot prune: sweep every tracked worktree and tear down any whose PR (assigned or
# actual branch) has merged/closed since last boot. cleanup_worktree only runs when a
# thread resolves, so without this sweep an agent that renames branches accumulates
# stale worktrees indefinitely. Runs once on startup; cheap (one gh pr view per
# tracked worktree, and only while there is a backlog).
prune_worktrees() {
  local root n=0
  while IFS=$'\t' read -r root _ _; do
    [ -n "$root" ] || continue
    cleanup_worktree "$root" && n=$((n + 1))
  done < "$WORKTREES"
  echo "[$AGENT_NAME] boot prune swept $n tracked worktrees"
}

# Detect if reply signals thread completion
is_thread_resolved() {
  local reply="$1"
  # Resolved patterns: PR link, explicit completion, pushed/merged/done
  echo "$reply" | grep -qiE '(github\.com/[^/]+/[^/]+/pull/[0-9]+|^Done\.|Pushed to|PR #[0-9]+|Merged|✅.*complete)'
}

# Worker: handle one message in the background (separate process)
worker() {
  local msg_id="$1" channel_id="$2" content="$3" root_id="$4" threaded="$5" directly="$6" msgs="$7"

  # Mark worker as running
  echo $$ > "$WORKERS/$msg_id.pid"

  # Eject: owner directly tells us to leave -> drop the thread + session and go silent
  # (just a 👋). Prevents an agent from lingering/meddling in a thread it was told off.
  if [ "$directly" = "1" ] && printf '%s' "$content" | grep -qiE "get out|leave (this|the) thread|not needed|stay out|butt out|back off|stand down|go away|you.?re done here|drop (it|this)|stop (helping|working|messing)"; then
    echo "[$AGENT_NAME worker-$$] leaving thread $root_id (owner asked)"
    (
      flock 200
      echo "$msg_id" >> "$SEEN"
      grep -v "^$root_id" "$THREADS" > "$THREADS.ej" 2>/dev/null && mv "$THREADS.ej" "$THREADS" || true
      grep -v "^$root_id" "$SESSIONS" > "$SESSIONS.ej" 2>/dev/null && mv "$SESSIONS.ej" "$SESSIONS" || true
    ) 200>"$SEEN.lock"
    "$BUZZ" reactions add --event "$msg_id" --emoji '👋' >/dev/null 2>&1 || true
    rm -f "$WORKERS/$msg_id.pid" "$WORKERS/root-$root_id.pid"
    return
  fi

  # Context lifecycle commands. /fresh drops harness memory for this turn but keeps
  # the worktree. /compact summarizes the existing pi session via RPC and does not
  # spend a model turn on the command itself. Agents can also schedule these for the
  # next turn with hidden [[WATCHER: ...]] directives (parsed from their reply below).
  fresh_mode=0
  compact_mode=0
  compact_instructions=""
  if [ "$directly" = "1" ] && printf '%s' "$content" | grep -qiE '^(@[A-Za-z0-9_-]+[[:space:]]+)?/fresh([[:space:]:]|$)'; then
    fresh_mode=1
    content="$(printf '%s' "$content" | sed -E 's#/fresh[:[:space:]]*##')"
    reset_thread_session "$root_id"
    "$BUZZ" reactions add --event "$msg_id" --emoji '🧹' >/dev/null 2>&1 || true
    echo "[$AGENT_NAME worker-$$] /fresh: cleared session for $root_id (worktree kept)"
  elif [ "$directly" = "1" ] && printf '%s' "$content" | grep -qiE '^(@[A-Za-z0-9_-]+[[:space:]]+)?/compact([[:space:]:]|$)'; then
    compact_mode=1
    compact_instructions="$(printf '%s' "$content" | sed -E 's#^(@[A-Za-z0-9_-]+[[:space:]]+)?/compact[:[:space:]]*##')"
    content=""
    echo "[$AGENT_NAME worker-$$] /compact requested for $root_id"
  elif [ -n "$root_id" ] && consume_fresh_next "$root_id"; then
    fresh_mode=1
    reset_thread_session "$root_id"
    echo "[$AGENT_NAME worker-$$] auto-fresh: cleared session for $root_id (worktree kept)"
  fi

  # Claim this message NOW (at-most-once), before any long-running work. Previously
  # seen was written only after a successful post; if the watcher died mid-turn - a
  # crash, or the 180s self-heal watchdog restarting it - the reply might have landed
  # but the seen-write was lost, so the next boot re-answered the same message. With
  # BOOT_GRACE=600s > the 180s restart interval, any active thread got re-answered on
  # every restart, which spammed a thread on 2026-07-10. Claiming up front makes a
  # restart idempotent. Trade-off: a message whose post genuinely fails is not retried
  # (the owner re-asks) - strictly better than an infinite re-answer loop.
  (
    flock 200
    grep -qxF "$msg_id" "$SEEN" 2>/dev/null || echo "$msg_id" >> "$SEEN"
  ) 200>"$SEEN.lock"

  if [ "$directly" = "1" ]; then verb="handling"; else verb="following"; fi
  echo "[$AGENT_NAME worker-$$] $verb $msg_id (root=$root_id)"
  # 👀 = actively working (set on thread root, removed before posting reply)
  reaction_target="$root_id"; [ -z "$reaction_target" ] && reaction_target="$msg_id"
  "$BUZZ" reactions add --event "$reaction_target" --emoji '👀' >/dev/null 2>&1 || true

  # When only following a thread (not directly addressed), let the agent stay silent
  # by replying [[SKIP]] (suppressed below).
  # No abstain layer: the FILTER already yields on our behalf (guests and
  # peer-addressed turns are dropped before we get here), so a message reaching this
  # worker is either a direct address or the OWNER's own untagged follow-up - both of
  # which we should just answer. (A prior [[SKIP]] abstain made owners skip their own
  # follow-up questions and poisoned the resumed session, so it was removed.)

  # Give the agent the concrete means to post progress updates mid-task (channel + root
  # + command). Only when directly asked to do something (not while just following).
  local POST_HINT=""
  POST_HINT="

## Progress updates (this thread)
If this is a multi-step task (edits, build, tests, PR), keep the owner posted as you go. After each milestone, run this to post into the thread (your key + relay are already in the env):
  buzz messages send --channel $channel_id --reply-to $root_id --content \"<one-line update>\"
Good moments: understood the task, found the code, building, tests pass, pushing, opened PR (include the link). Keep each to one line. Do NOT post your final summary this way - whatever you print as your final message is posted to the thread automatically, so self-posting it would duplicate.

Post at least one mid-work update for any task running more than ~2 minutes of tool activity. If you reach your final message without having posted one, you missed it. Quick answers (pure read + reply, no tool activity) are the exception - skip updates for those."

  sid="$(get_session "$root_id")"
  work_dir="$(get_worktree "$root_id")"

  # HEAD guard: if the worktree exists but the agent switched it off the
  # watcher-assigned branch (e.g. created a custom-named branch), log it so the
  # misbehavior is visible. cleanup_worktree still handles teardown via the actual
  # branch. (one production agent did this, leaving 45 stale worktrees.)
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    _assigned="$(get_worktree_branch "$root_id")"
    _actual="$(git -C "$work_dir" branch --show-current 2>/dev/null || echo "")"
    if [ -n "$_actual" ] && [ -n "$_assigned" ] && [ "$_actual" != "$_assigned" ]; then
      echo "[$AGENT_NAME worker-$$] note: worktree $work_dir on branch '$_actual', assigned '$_assigned' (renamed to the repo's scheme; cleanup handles both)"
    fi
  fi

  # Context budget: on a resumed session the harness session already holds the full
  # conversation history, so re-sending every prior message bloats context (cost,
  # latency, accuracy). Instead send only messages that arrived AFTER the last turn we
  # answered (peer bot messages + the current one), and drop ambient room context.
  # First turn of a thread: send full thread history. Always drop ambient to prevent
  # cross-thread context bleed (decision 2026-07-13); the agent can search old
  # messages via `buzz messages` tools if broader channel context is needed.
  THREAD_JSON="[]"
  if [ "$threaded" = "1" ] && [ -n "$root_id" ]; then
    THREAD_JSON="$("$BUZZ" messages thread --channel "$channel_id" --event "$root_id" 2>/dev/null || echo '[]')"
  fi
  # /fresh: start clean - no thread history in the prompt. The agent reads the spec
  # from disk in the worktree instead of carrying the discovery conversation forward.
  [ "${fresh_mode:-0}" = "1" ] && THREAD_JSON="[]"
  CURRENT_JSON="$(get_msg_by_id "$msg_id" "$msgs")"
  [ -z "$CURRENT_JSON" ] && CURRENT_JSON="$(printf '%s' "$content" | python3 -c "
import sys, json
print(json.dumps({'id': sys.argv[1], 'content': sys.stdin.read(), 'pubkey': sys.argv[2]}))
" "$msg_id" "$OWNER")"
  # /fresh: strip the directive from the message the agent sees (the watcher already
  # acted on it). Preserve the real pubkey from the original message object.
  if [ "${fresh_mode:-0}" = "1" ]; then
    _orig_pub="$(printf '%s' "$CURRENT_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("pubkey",""))' 2>/dev/null || true)"
    [ -z "$_orig_pub" ] && _orig_pub="$OWNER"
    CURRENT_JSON="$(printf '%s' "$content" | python3 -c '
import sys, json
print(json.dumps({"id": sys.argv[1], "content": sys.stdin.read(), "pubkey": sys.argv[2]}))
' "$msg_id" "$_orig_pub")"
  fi

  SINCE_TS="0"
  lastturn="$(get_lastturn "$root_id")"
  if [ -n "$sid" ] && [ -n "$lastturn" ]; then
    SINCE_TS="$lastturn"
  fi
  RECENT_JSON="[]"

  if [ -n "$sid" ]; then
    # Resuming: run in the same dir the session was created in. direct-main agents
    # never made a worktree, and a builder's worktree may have been cleaned up
    # after its PR merged - fall back to the main repo so `pi --session` / `claude
    # --resume` finds the session (an empty work_dir would run in the wrong project).
    [ -z "$work_dir" ] && work_dir="$AGENT_REPO"
  else
    # New thread: direct-main agents work in the main repo; branch-pr
    # agents get an isolated per-thread worktree cut from fresh main.
    if [ -z "$work_dir" ]; then
      if [ "$AGENT_GUARDRAIL" = "direct-main" ]; then work_dir="$AGENT_REPO"; else work_dir="$(create_worktree "$root_id")"; fi
    fi
  fi

  # Map canonical model name to harness-specific format. Compaction uses the same
  # model as the agent turn so the summary matches the session's reasoning style.
  # While the primary is limited, run on the fallback harness from the start. The window
  # expires on its own; primary_is_limited clears the marker once the clock passes it, so
  # reverting needs no timer and no separate job.
  local turn_harness="$AGENT_HARNESS" turn_model="$AGENT_MODEL" turn_sid="$sid" on_fallback=0
  if [ -n "${AGENT_FALLBACK_HARNESS:-}" ] && primary_is_limited; then
    turn_harness="$AGENT_FALLBACK_HARNESS"; turn_model="${AGENT_FALLBACK_MODEL:-$AGENT_MODEL}"
    turn_sid=""   # the fallback cannot resume the primary's session
    on_fallback=1
    echo "[$AGENT_NAME worker-$$] primary limited until $(cat "$LIMITED" 2>/dev/null); using $turn_harness"
  fi

  local harness_model
  harness_model="$(map_model_name "$turn_harness" "$turn_model")"

  # Manual /compact is watcher-only: compact the existing session, post the outcome,
  # and return without invoking the agent for a paid turn.
  if [ "${compact_mode:-0}" = "1" ]; then
    reply_target="$root_id"; [ -z "$reply_target" ] && reply_target="$msg_id"
    "$BUZZ" reactions remove --event "$reply_target" --emoji '👀' >/dev/null 2>&1 || true
    if [ -z "$sid" ]; then
      compact_result=$'noop\t0\t0\tno harness session exists yet'
    else
      compact_result="$(compact_session_any "$AGENT_HARNESS" "$root_id" "$sid" "$harness_model" "$work_dir" "$compact_instructions")"
    fi
    compact_status="$(printf '%s' "$compact_result" | awk -F'\t' '{print $1}')"
    compact_before="$(printf '%s' "$compact_result" | awk -F'\t' '{print $2}')"
    compact_after="$(printf '%s' "$compact_result" | awk -F'\t' '{print $3}')"
    compact_message="$(printf '%s' "$compact_result" | cut -f4-)"
    case "$compact_status" in
      ok) control_reply="Context compacted: ${compact_before} -> ${compact_after} estimated tokens." ;;
      ok-seeded) control_reply="Context compacted into a ~${compact_after} token carry-over summary. The next message in this thread starts a fresh session seeded with it." ;;
      noop) control_reply="No compaction needed: ${compact_message}." ;;
      *) control_reply="Context compaction failed: ${compact_message}. The session was left unchanged." ;;
    esac
    echo "[$AGENT_NAME worker-$$] compact $compact_status for $root_id: $compact_message"
    "$BUZZ" messages send --channel "$channel_id" --reply-to "$reply_target" --content "$control_reply" >/dev/null 2>&1 || echo "[$AGENT_NAME worker-$$] compact status post failed for $msg_id"
    "$BUZZ" reactions add --event "$reply_target" --emoji '🧹' >/dev/null 2>&1 || true
    rm -f "$WORKERS/$msg_id.pid" "$WORKERS/root-$root_id.pid"
    return 0
  fi

  prompt="$(printf '%s\n%s\n%s\n' "$THREAD_JSON" "$RECENT_JSON" "$CURRENT_JSON" | python3 -c "$FORMAT_CONTEXT" "$OWNER" "$BOT_PUB" "$AGENT_NAME" "$AGENT_ROSTER_FILE" "$SINCE_TS")$POST_HINT"

  # A compacted thread starts clean but not empty: the summary written by generic_compact
  # is prepended once, then consumed. Without this the compaction would just be a /fresh
  # that also cost a turn.
  if [ -n "$root_id" ] && [ -f "$CARRY/$root_id.md" ]; then
    prompt="$(printf 'Context carried over from the compacted session:\n\n%s\n\n---\n\n%s' "$(cat "$CARRY/$root_id.md")" "$prompt")"
    rm -f "$CARRY/$root_id.md"
    echo "[$AGENT_NAME worker-$$] seeded fresh session from carry-over for $root_id"
  fi

  # Record the timestamp of the message we're answering, so the next resume only pulls
  # messages newer than this (older history is already in the session).
  cur_ts="$(printf '%s' "$CURRENT_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('created_at',0) or 0)" 2>/dev/null || echo 0)"
  [ -n "$cur_ts" ] && [ "$cur_ts" != "0" ] && set_lastturn "$root_id" "$cur_ts"

  out_file="$(mktemp)"

  # Run agent with timeout using harness adapter
  invoke_harness "$turn_harness" "$out_file" "$prompt" "$harness_model" "$turn_sid" "$work_dir" "$SYSTEM_PROMPT" &

  local gpid=$!
  ( sleep "$MODEL_TIMEOUT"; kill -TERM "$gpid" 2>/dev/null; sleep 3; kill -KILL "$gpid" 2>/dev/null ) &
  local tpid=$!
  wait "$gpid" 2>/dev/null
  kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null

  # Extract result and session using harness-aware extraction
  reply="$(extract_harness_field "$turn_harness" "$out_file" result)"
  new_sid="$(extract_harness_field "$turn_harness" "$out_file" session_id)"
  cost_data="$(extract_harness_field "$turn_harness" "$out_file" cost)"

  # The limit notice arrives as a normal-looking reply. Catch it before it is posted,
  # record the reset time, and re-run this turn on the fallback with the conversation
  # bridged across - otherwise the owner gets the notice instead of an answer.
  limit_until="$(session_limit_until "$reply")"
  if [ -n "$limit_until" ]; then
    printf '%s\n' "$limit_until" > "$LIMITED"
    echo "[$AGENT_NAME worker-$$] $turn_harness hit its session limit; resets $(date -r "$limit_until" +%H:%M)"
    if [ -n "${AGENT_FALLBACK_HARNESS:-}" ] && [ "$turn_harness" = "$AGENT_HARNESS" ]; then
      turn_harness="$AGENT_FALLBACK_HARNESS"; turn_model="${AGENT_FALLBACK_MODEL:-$AGENT_MODEL}"
      harness_model="$(map_model_name "$turn_harness" "$turn_model")"
      bridge="$(bridge_from_transcript "$sid" "$work_dir")"
      out_file="$(mktemp)"
      echo "[$AGENT_NAME worker-$$] retrying on $turn_harness ($harness_model), bridge $(printf '%s' "$bridge" | wc -c | tr -d ' ') chars"
      invoke_harness "$turn_harness" "$out_file" "$(printf '%s\n\n---\n\n%s' "$bridge" "$prompt")" "$harness_model" "" "$work_dir" "$SYSTEM_PROMPT" &
      gpid=$!
      ( sleep "$MODEL_TIMEOUT"; kill -TERM "$gpid" 2>/dev/null; sleep 3; kill -KILL "$gpid" 2>/dev/null ) & tpid=$!
      wait "$gpid" 2>/dev/null; kill "$tpid" 2>/dev/null; wait "$tpid" 2>/dev/null
      reply="$(extract_harness_field "$turn_harness" "$out_file" result)"
      new_sid=""; on_fallback=1   # do not overwrite the primary's session id with the fallback's
      cost_data="$(extract_harness_field "$turn_harness" "$out_file" cost)"
    fi
  fi
  # A PPQ 402 (drained balance) produces an empty reply - flag it before the out_file goes.
  ppq_outage=0
  { [ -z "$reply" ] || [ "$reply" = "null" ]; } && ppq_output_is_402 "$out_file" && ppq_outage=1
  rm -f "$out_file"

  # A fallback session id is unusable by the primary: once the limit window expires the
  # primary resumes an id it has never heard of, every turn dies instantly with "No
  # conversation found", and the thread goes silent (2026-09-02). The fallback always
  # runs with turn_sid="" anyway, so there is nothing to keep.
  [ -n "$new_sid" ] && [ "$on_fallback" = 0 ] && set_session "$root_id" "$new_sid"

  # Track cost if the harness reports it (per-thread cumulative; thread-safe).
  cost_cents=""
  prev_cost_cents=""
  if [ -n "$cost_data" ] && [ "$cost_data" != "0.0:0" ]; then
    turn_cost="${cost_data%%:*}"; turn_tokens="${cost_data##*:}"
    # Capture previous cumulative BEFORE add_cost overwrites it (for reaction cleanup).
    prev="$(get_cost "$root_id")"
    if [ -n "$prev" ]; then
      prev_cum="${prev%%:*}"
      prev_cost_cents="$(python3 -c "print(int(round($prev_cum * 100)))" 2>/dev/null || echo "0")"
    fi
    cumulative="$(add_cost "$root_id" "$turn_cost" "$turn_tokens")"
    cum_cost="${cumulative%%:*}"; cum_tokens="${cumulative##*:}"
    cost_cents="$(python3 -c "print(int(round($cum_cost * 100)))" 2>/dev/null || echo "0")"
    echo "[$AGENT_NAME worker-$$] thread $root_id cost: \$${cum_cost} (${cum_tokens} tokens, ${cost_cents}c)"
  fi

  # 402 = drained balance, not a real turn. Post a debounced top-up alert (with a fresh
  # LN invoice) instead of the generic "(no reply produced)" and bail out of this worker.
  if [ "$ppq_outage" = 1 ]; then
    reply_target="$root_id"; [ -z "$reply_target" ] && reply_target="$msg_id"
    echo "[$AGENT_NAME worker-$$] PPQ 402 (balance drained) on $msg_id - posting top-up alert"
    ppq_alert "$BUZZ" "$channel_id" "$reply_target"
    "$BUZZ" reactions remove --event "$reply_target" --emoji '👀' >/dev/null 2>&1 || true
    rm -f "$WORKERS/$msg_id.pid" "$WORKERS/root-$root_id.pid"
    return 0
  fi

  # Hidden watcher directives let the agent manage its own context between turns.
  # They must be on their own final line and are stripped before posting.
  watcher_action=""
  watcher_action_instructions=""
  if [ -n "$reply" ]; then
    reply_in="$(mktemp)"; parsed_json="$(mktemp)"
    printf '%s' "$reply" > "$reply_in"
    python3 - "$reply_in" > "$parsed_json" <<'PY'
import json
import re
import sys

text = open(sys.argv[1]).read()
actions = []
pattern = re.compile(r"^\s*\[\[WATCHER:\s*(fresh|compact)(?::\s*(.*?))?\]\]\s*$", re.IGNORECASE | re.MULTILINE)

def replace(match):
    if not actions:
        actions.append({
            "action": match.group(1).lower(),
            "instructions": (match.group(2) or "").strip()[:500],
        })
    return ""

clean = pattern.sub(replace, text).strip()
if not clean:
    clean = "Context lifecycle update scheduled."
print(json.dumps({"reply": clean, "action": actions[0] if actions else None}))
PY
    reply="$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1]))["reply"])' "$parsed_json" 2>/dev/null || cat "$reply_in")"
    watcher_action="$(python3 -c 'import sys,json; a=json.load(open(sys.argv[1])).get("action") or {}; print(a.get("action", ""))' "$parsed_json" 2>/dev/null || true)"
    watcher_action_instructions="$(python3 -c 'import sys,json; a=json.load(open(sys.argv[1])).get("action") or {}; print(a.get("instructions", ""))' "$parsed_json" 2>/dev/null || true)"
    rm -f "$reply_in" "$parsed_json"
  fi

  # Reply guard (mirrors upstream buzz-agent's BUZZ_AGENT_REQUIRE_REPLY): a turn that
  # ran but produced no visible reply is almost always a silent model turn (deepseek
  # thinking-only turns, 2026-08-06). Nudge the same session once before falling back
  # to the "(no reply produced)" placeholder.
  if { [ -z "$reply" ] || [ "$reply" = "null" ]; } && [ "${REPLY_GUARD:-1}" = "1" ]; then
    echo "[$AGENT_NAME worker-$$] empty reply on $msg_id - re-prompting once (reply guard)"
    local retry_out retry_sid retry_pid retry_tpid eff_sid
    eff_sid="${new_sid:-$sid}"; [ "$on_fallback" = 1 ] && eff_sid=""
    retry_out="$(mktemp)"
    invoke_harness "$turn_harness" "$retry_out" "Your previous turn completed without posting any reply. The user is still waiting. Post your response now with the buzz CLI per your instructions. If you are blocked, say so plainly." "$harness_model" "$eff_sid" "$work_dir" "$SYSTEM_PROMPT" &
    retry_pid=$!
    ( sleep "$MODEL_TIMEOUT"; kill -TERM "$retry_pid" 2>/dev/null; sleep 3; kill -KILL "$retry_pid" 2>/dev/null ) &
    retry_tpid=$!
    wait "$retry_pid" 2>/dev/null
    kill "$retry_tpid" 2>/dev/null; wait "$retry_tpid" 2>/dev/null
    reply="$(extract_harness_field "$turn_harness" "$retry_out" result)"
    retry_sid="$(extract_harness_field "$turn_harness" "$retry_out" session_id)"
    rm -f "$retry_out"
    [ "$reply" = "null" ] && reply=""
    [ -n "$retry_sid" ] && [ "$on_fallback" = 0 ] && { new_sid="$retry_sid"; set_session "$root_id" "$new_sid"; }
  fi

  [ -z "$reply" ] && reply="(no reply produced - check $STATE logs)"

  reply_target="$root_id"; [ -z "$reply_target" ] && reply_target="$msg_id"

  # Remove 👀 from thread root before posting final reaction
  "$BUZZ" reactions remove --event "$reply_target" --emoji '👀' >/dev/null 2>&1 || true

  # Capture both streams: the CLI reports failures as JSON on stdout, so redirecting
  # into a variable is the only way to learn why a post was rejected. Discarding it
  # made "post failed" unexplainable (2026-09-02).
  local send_out send_rc
  send_out="$("$BUZZ" messages send --channel "$channel_id" --reply-to "$reply_target" --content "$reply" 2>&1)"
  send_rc=$?
  if [ "$send_rc" -eq 0 ]; then
    # (msg_id was already marked seen at worker start, above.) Record our thread role
    # on first engagement: owner if we started it (engaged via the root message),
    # guest if pulled into an existing thread.
    (
      flock 200
      if ! awk -F'\t' -v r="$root_id" '$1==r{f=1} END{exit !f}' "$THREADS" 2>/dev/null; then
        if [ "$msg_id" = "$root_id" ]; then role="owner"; else role="guest"; fi
        printf '%s\t%s\n' "$root_id" "$role" >> "$THREADS"
      fi
    ) 200>"$THREADS.lock"

    # Apply a hidden context lifecycle directive only after the human-visible reply
    # landed. Fresh is deferred to the next turn; compact runs now, while the worktree
    # and session id are still known.
    case "$watcher_action" in
      fresh)
        reset_thread_session "$root_id"
        mark_fresh_next "$root_id"
        echo "[$AGENT_NAME worker-$$] agent requested fresh next session for $root_id"
        ;;
      compact)
        sid_for_compact="$new_sid"; [ -z "$sid_for_compact" ] && sid_for_compact="$sid"
        if [ -n "$sid_for_compact" ]; then
          [ -z "$watcher_action_instructions" ] && watcher_action_instructions="Preserve exact file paths, failing commands, errors, decisions, and next steps."
          compact_result="$(compact_session_any "$AGENT_HARNESS" "$root_id" "$sid_for_compact" "$harness_model" "$work_dir" "$watcher_action_instructions")"
          compact_status="$(printf '%s' "$compact_result" | awk -F'\t' '{print $1}')"
          compact_message="$(printf '%s' "$compact_result" | cut -f4-)"
          echo "[$AGENT_NAME worker-$$] agent-requested compact $compact_status for $root_id: $compact_message"
        else
          echo "[$AGENT_NAME worker-$$] agent requested compact for $root_id, but no session id is known"
        fi
        ;;
    esac

    # Set final reaction on thread root based on thread state
    # Remove both status reactions first so only the current one remains (idempotent).
    "$BUZZ" reactions remove --event "$reply_target" --emoji '✅' >/dev/null 2>&1 || true
    "$BUZZ" reactions remove --event "$reply_target" --emoji '💬' >/dev/null 2>&1 || true
    if is_thread_resolved "$reply"; then
      # ✅ = thread resolved (PR link, explicit done, etc.)
      "$BUZZ" reactions add --event "$reply_target" --emoji '✅' >/dev/null 2>&1 || true
      cleanup_worktree "$root_id"
      echo "[$AGENT_NAME worker-$$] completed $msg_id (resolved)"
    else
      # 💬 = waiting for your response (agent finished turn, thread still open)
      "$BUZZ" reactions add --event "$reply_target" --emoji '💬' >/dev/null 2>&1 || true
      echo "[$AGENT_NAME worker-$$] completed $msg_id (waiting)"
    fi

    # Cost reaction (cumulative cents) if the harness reported cost this turn.
    # Remove the previous cost reaction before adding the updated one so only the
    # latest cumulative total shows (prev_cost_cents was captured before add_cost).
    if [ -n "$cost_cents" ] && [ "$cost_cents" != "0" ]; then
      if [ -n "$prev_cost_cents" ] && [ "$prev_cost_cents" != "0" ] && [ "$prev_cost_cents" != "$cost_cents" ]; then
        "$BUZZ" reactions remove --event "$reply_target" --emoji ":${prev_cost_cents}c:" >/dev/null 2>&1 || true
      fi
      "$BUZZ" reactions add --event "$reply_target" --emoji ":${cost_cents}c:" >/dev/null 2>&1 || true
    fi
  else
    # A failed post loses the whole turn's answer, so keep it on disk to recover from.
    mkdir -p "$STATE/failed-posts"
    printf '%s' "$reply" > "$STATE/failed-posts/$msg_id.txt"
    echo "[$AGENT_NAME worker-$$] post failed for $msg_id (rc=$send_rc, ${#reply} chars): $(printf '%s' "$send_out" | tr '\n' ' ' | cut -c1-400)"
    echo "[$AGENT_NAME worker-$$] reply saved to $STATE/failed-posts/$msg_id.txt"
  fi

  # Remove worker pid file + release the per-thread lock
  rm -f "$WORKERS/$msg_id.pid"
  rm -f "$WORKERS/root-$root_id.pid"
}

# Reap finished workers and enforce max concurrency.
# Counts root-*.pid only: each live worker writes TWO pid files (<msg_id>.pid and
# root-<root_id>.pid), so globbing *.pid double-counted and halved MAX_WORKERS.
# root-*.pid is also the one holding the real worker pid - <msg_id>.pid gets $$,
# which bash does not re-evaluate in a backgrounded function, so it holds the
# watcher's own pid and its staleness check can never fire.
active_worker_count() {
  local count=0
  for pidfile in "$WORKERS"/root-*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    else
      rm -f "$pidfile"  # stale pidfile
    fi
  done
  echo "$count"
}

# Main loop: poll for messages, spawn workers.
# Boot baseline: suppress pre-existing HISTORY older than BOOT_GRACE only, so a mention
# that arrived just before a restart is NOT swallowed (already-answered recent ones
# stay skipped via the persistent seen list).
KNOWN=""
boot_cutoff=$(( $(date +%s) - BOOT_GRACE ))
for cid in $(list_channel_ids); do
  "$BUZZ" messages get --channel "$cid" 2>/dev/null | python3 -c 'import sys, json
cut = int(sys.argv[1])
try:
    for m in json.load(sys.stdin):
        if m.get("created_at", 0) < cut: print(m.get("id", ""))
except: pass' "$boot_cutoff" >> "$SEEN"
  KNOWN="${KNOWN}${cid}
"
done
"$BUZZ" users set-presence --status online >/dev/null 2>&1 || true
write_channel_map
prune_worktrees
echo "[$AGENT_NAME] up. model=$AGENT_MODEL repo=$AGENT_REPO pub=${BOT_PUB:0:12} workers=0/$MAX_WORKERS channels=$(list_channel_ids | tr '\n' ' ')"

while true; do
  spawned_roots=" "   # roots dispatched THIS poll cycle (space-delimited)
  # Wait if at max worker capacity
  while [ "$(active_worker_count)" -ge "$MAX_WORKERS" ]; do
    sleep 2
  done

  for cid in $(list_channel_ids); do
    case "$KNOWN" in *"$cid"*) : ;; *) KNOWN="${KNOWN}${cid}
"; echo "[$AGENT_NAME] now watching new channel $cid"; write_channel_map ;; esac

    MSGS="$("$BUZZ" messages get --channel "$cid" 2>/dev/null)"
    [ -z "$MSGS" ] && continue

    mo=0; is_summon_only "$cid" && mo=1   # summon-only (guest) in this channel?

    while IFS=$'\t' read -r id b64 root_id threaded directly; do
      [ -z "$id" ] && continue

      # Skip if already being worked on
      [ -f "$WORKERS/$id.pid" ] && continue

      # Skip if already seen (thread-safe check)
      (
        flock 200
        grep -qxF "$id" "$SEEN" 2>/dev/null && exit 0 || exit 1
      ) 200>"$SEEN.lock" && continue

      # Serialize per thread: messages in one thread share a single claude session,
      # and concurrent --resume corrupts it (empty replies). Only one worker per root
      # at a time - both within this poll and across polls while one is still running.
      case "$spawned_roots" in *" $root_id "*) continue ;; esac
      rootpid="$WORKERS/root-$root_id.pid"
      if [ -f "$rootpid" ] && kill -0 "$(cat "$rootpid" 2>/dev/null)" 2>/dev/null; then continue; fi

      # Wait if at capacity
      while [ "$(active_worker_count)" -ge "$MAX_WORKERS" ]; do
        sleep 1
      done

      content="$(printf '%s' "$b64" | base64 -d 2>/dev/null)"

      # Spawn worker in background; record its pid as the per-thread lock
      worker "$id" "$cid" "$content" "$root_id" "$threaded" "$directly" "$MSGS" &
      echo $! > "$rootpid"
      spawned_roots="$spawned_roots$root_id "

    done < <(printf '%s' "$MSGS" | python3 -c "$FILTER" "$SEEN" "$OWNER" "$AGENT_NAME" "$THREADS" "$AGENT_PEERS_FILE" "$BOT_PUB" "$mo" "$AGENT_ASSIST_FILE")
  done

  sleep 5
done
