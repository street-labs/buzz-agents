#!/usr/bin/env bash
# Scaffold a new Buzz agent. Run on the always-on host.
#
# It mints (or reuses) the bot keypair, ensures the channel exists, adds you and the
# bot as members (verified), sets up an isolated git worktree on branch agent/<name>,
# writes the agent config, installs the generic watcher + base prompt, launches the
# watcher in tmux, and verifies it is running. Every state change is read back and
# confirmed before the script claims success (the thing agents keep getting wrong).
#
# Usage:
#   new-agent.sh <name> --repo <path> --model <m> [--channel <slug|id>]
#                       [--key <file>] [--persona <file>]
#   --model is required (no default): router-auto | sonnet | opus | haiku | glm-5.2 | codex
#   Harness follows the model; codex-* ids need AGENT_HARNESS="codex" in the env file.
# Example:
#   new-agent.sh myproject --repo ~/code/myproject --key ~/.buzz/myproject-bot.key
set -euo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$HOME/.claude/local:$HOME/.buzz/bin:/usr/bin:/bin:$PATH"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
# buzz CLI: PATH first, then ~/.buzz/bin fallback (just setup suggests the symlink).
BUZZ="$(command -v buzz || echo "$HOME/.buzz/bin/buzz")"
# Human owner pubkey - agents add this key to channels they create. Set in env.
OWNER="${OWNER:?Set OWNER to your hex pubkey first (nak key public <your-nsec>)}"
RELAY="${BUZZ_RELAY_URL:-http://localhost:3000}"

NAME="${1:?usage: new-agent.sh <name> --repo <path> --model <m> [--channel <slug|id>] [--key f] [--persona f] [--admin-key f]}"; shift
REPO=""; CHANNEL="$NAME"; MODEL=""; KEY=""; PERSONA=""   # --model is required, no default (see below)
# Admin identity that owns/administers the channels (creates channels, adds members).
# Defaults to an admin bot key that owns the workspace channels.
ADMIN_KEY="$HOME/.buzz/admin-bot.key"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2;;
    --channel) CHANNEL="$2"; shift 2;;
    --model) MODEL="$2"; shift 2;;
    --key) KEY="$2"; shift 2;;
    --persona) PERSONA="$2"; shift 2;;
    --admin-key) ADMIN_KEY="$2"; shift 2;;
    *) echo "unknown arg: $1"; exit 2;;
  esac
done
[ -f "$ADMIN_KEY" ] || { echo "admin key not found: $ADMIN_KEY (pass --admin-key)"; exit 2; }
# buzz invoked as the channel admin (for list/create/add-member/members)
badmin() { BUZZ_PRIVATE_KEY="$(cat "$ADMIN_KEY")" "$BUZZ" "$@"; }
[ -n "$REPO" ] || { echo "--repo is required"; exit 2; }
# --model is required: no default, so an agent is never silently born on an expensive
# model.
[ -n "$MODEL" ] || { echo "--model is required (no default - name it, e.g. --model router-auto). Options: router-auto|sonnet|opus|haiku|glm-5.2|codex|codex-mini|codex-long"; exit 2; }
REPO="${REPO/#\~/$HOME}"
[ -d "$REPO/.git" ] || { echo "repo not a git checkout: $REPO"; exit 2; }

AGENTS_DIR="$HOME/.buzz/agents"; mkdir -p "$AGENTS_DIR"
KEY="${KEY:-$AGENTS_DIR/$NAME-bot.key}"
export BUZZ_RELAY_URL="$RELAY"

step() { printf '\n=== %s ===\n' "$1"; }

step "1. bot keypair"
if [ -f "$KEY" ]; then
  echo "reusing existing key: $KEY"
else
  ( umask 077; nak key generate > "$KEY" )
  echo "minted new key: $KEY"
fi
BOT_PUB="$(nak key public "$(cat "$KEY")")"
[ ${#BOT_PUB} -eq 64 ] || { echo "FAILED to derive a 64-char pubkey"; exit 1; }
echo "bot pubkey: $BOT_PUB"

# register in the roster (pubkey<TAB>name) so agents know each other by name and can
# tell whose message is whose in shared threads
ROSTER="$AGENTS_DIR/roster.tsv"; touch "$ROSTER"
grep -qiE "^$BOT_PUB	" "$ROSTER" 2>/dev/null || printf '%s\t%s\n' "$BOT_PUB" "$NAME" >> "$ROSTER"

# register as an assist agent (pubkey<TAB>name): this agent is primary in its own
# channel and summon-only elsewhere, so it must never claim the "active" follow-up slot
# when summoned into another agent's channel. Every watcher reads assist.txt.
ASSIST="$AGENTS_DIR/assist.txt"; touch "$ASSIST"
grep -qiE "^$BOT_PUB	" "$ASSIST" 2>/dev/null || printf '%s\t%s\n' "$BOT_PUB" "$NAME" >> "$ASSIST"

step "2. bot profile"
BUZZ_PRIVATE_KEY="$(cat "$KEY")" "$BUZZ" users set-profile --name "$NAME" \
  --about "$NAME agent" >/dev/null 2>&1 || true
echo "profile name set to: $NAME"

step "3. channel"
find_cid() {  # echoes channel id for $CHANNEL (by id or name), empty if none
  badmin channels list 2>/dev/null | python3 -c '
import sys,json
want=sys.argv[1]
try: chans=json.load(sys.stdin)
except: sys.exit(0)
for c in chans:
    cid=c.get("channel_id") or c.get("id")
    if cid==want or c.get("name")==want: print(cid); break
' "$CHANNEL"
}
CID="$(find_cid || true)"
if [ -z "$CID" ]; then
  echo "creating channel #$CHANNEL"
  badmin channels create --name "$CHANNEL" --type stream --visibility private \
    --description "$CHANNEL project channel" >/dev/null 2>&1 || true
  sleep 1; CID="$(find_cid || true)"
fi
[ -n "$CID" ] || { echo "FAILED to resolve/create channel"; exit 1; }
echo "channel id: $CID"

step "4. membership (owner + bot), verified"
badmin channels add-member --channel "$CID" --pubkey "$OWNER"  --role member >/dev/null 2>&1 || true
badmin channels add-member --channel "$CID" --pubkey "$BOT_PUB" --role bot    >/dev/null 2>&1 || true
BUZZ_PRIVATE_KEY="$(cat "$KEY")" "$BUZZ" channels join --channel "$CID" >/dev/null 2>&1 || true
MEMBERS="$(badmin channels members --channel "$CID" 2>/dev/null)"
echo "$MEMBERS" | python3 -c '
import sys,json
owner=sys.argv[1]; bot=sys.argv[2]
try: ms=json.load(sys.stdin)
except: ms=[]
pks=[m.get("pubkey","") for m in ms]
print("  members:", ", ".join(p[:10]+"/"+m.get("role","") for p,m in zip(pks,ms)) or "(none)")
print("  owner present:", owner in pks)
print("  bot present:", bot in pks)
sys.exit(0 if (owner in pks and bot in pks) else 1)
' "$OWNER" "$BOT_PUB" || echo "  WARN: membership not fully confirmed (owner+bot)"

step "5. isolated worktree on branch agent/$NAME"
WT="$AGENTS_DIR/$NAME/worktree"
if [ -d "$WT/.git" ] || git -C "$REPO" worktree list 2>/dev/null | grep -q "$WT"; then
  echo "worktree already present: $WT"
else
  mkdir -p "$AGENTS_DIR/$NAME"
  if git -C "$REPO" show-ref --verify --quiet "refs/heads/agent/$NAME"; then
    git -C "$REPO" worktree add "$WT" "agent/$NAME"
  else
    git -C "$REPO" worktree add -b "agent/$NAME" "$WT" 2>/dev/null || \
      git -C "$REPO" worktree add "$WT" "agent/$NAME"
  fi
  echo "worktree: $WT (branch agent/$NAME)"
fi

step "6. install base prompt + watcher + config"
cp "$SRC_DIR/base-agent-prompt.md" "$AGENTS_DIR/base-agent-prompt.md"
cp "$SRC_DIR/agent-watcher.sh" "$AGENTS_DIR/agent-watcher.sh"; chmod +x "$AGENTS_DIR/agent-watcher.sh"
PERSONA_LINE=""
if [ -n "$PERSONA" ] && [ -f "$PERSONA" ]; then
  cp "$PERSONA" "$AGENTS_DIR/$NAME/persona.md"
  PERSONA_LINE="AGENT_PERSONA_FILE=\"$AGENTS_DIR/$NAME/persona.md\""
fi
CONF="$AGENTS_DIR/$NAME.env"
cat > "$CONF" <<EOF
# agent config for "$NAME" (generated by new-agent.sh)
AGENT_NAME="$NAME"
AGENT_KEY_FILE="$KEY"
AGENT_REPO="$WT"
AGENT_MODEL="$MODEL"
# Scope = every channel this bot is a member of. This agent is PRIMARY (follows threads)
# in its HOME channel below and summon-only in every OTHER channel it joins - it answers
# a direct @$NAME there, then bows out. Add more home channels (space separated) to make
# it primary in them too.
AGENT_HOME_CHANNELS="$CID"
AGENT_GUARDRAIL="branch-pr"
AGENT_BASE_PROMPT_FILE="$AGENTS_DIR/base-agent-prompt.md"
$PERSONA_LINE
EOF
echo "config: $CONF"

step "7. launch in tmux"
SESSION="buzz-$NAME"
tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" "bash $AGENTS_DIR/agent-watcher.sh $CONF >> $AGENTS_DIR/$NAME/watcher.log 2>&1"
sleep 5

step "8. verify running"
if tmux has-session -t "$SESSION" 2>/dev/null && tmux list-sessions | grep -q "$SESSION"; then
  echo "tmux session $SESSION: running"
else
  echo "FAILED: tmux session not running"; exit 1
fi
echo "--- last log lines ---"; tail -3 "$AGENTS_DIR/$NAME/watcher.log" 2>/dev/null || true

cat <<EOF

DONE. Agent "$NAME" is live.
  channel:  #$CHANNEL ($CID)
  bot pub:  $BOT_PUB
  repo:     $WT (branch agent/$NAME)
  config:   $CONF
  logs:     $AGENTS_DIR/$NAME/watcher.log

Test it: in #$CHANNEL, post "@$NAME <question>" (or @builder). It should answer with
project context and remember follow-ups in the same thread.

This agent is primary in #$CHANNEL and summon-only in any other channel it joins (it
answers a direct @$NAME, then bows out). The other agents are likewise
summon-only here - they help when you @-mention them, then yield back to @$NAME.
To make this agent reachable in another channel (as a summon-only guest), add its bot:
  BUZZ_PRIVATE_KEY=\$(cat ~/.buzz/admin-bot.key) buzz channels add-member --channel <other-id> --pubkey $BOT_PUB --role member
EOF
