#!/usr/bin/env bash
# Exercises warm-slots.sh against a scratch repo: which slots it picks, and more
# importantly which it refuses to touch. Run: bash test-warm-slots.sh
set -u
WARM="$(cd "$(dirname "$0")" && pwd)/warm-slots.sh"
T=$(mktemp -d)
export HOME="$T/home"
mkdir -p "$HOME/.buzz/agents/builder"
git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/repo" 2>/dev/null
cd "$T/repo" || exit 1
git config user.email t@t.t; git config user.name t
mkdir -p tools
echo hi > a.txt; git add -A; git commit -qm init; git branch -M main; git push -q origin main

# stand-in for the project's real build: records that it ran, writes the marker
cat > tools/agent-warm-slot.sh <<'INNER'
#!/bin/sh
echo "$PWD" >> "$WARM_RAN_LOG"
git rev-parse HEAD > "$(git rev-parse --absolute-git-dir)/agent-warmed-sha"
INNER
chmod +x tools/agent-warm-slot.sh
git add -A; git commit -qm tools; git push -q origin main

export WARM_RAN_LOG="$T/ran.log"; : > "$WARM_RAN_LOG"
printf 'AGENT_REPO=%s\n' "$T/repo" > "$HOME/.buzz/agents/builder/agent.env"
WT="$T/repo-worktrees"; mkdir -p "$WT"
: > "$HOME/.buzz/agents/builder/worktrees.tsv"
for n in 0 1 2; do git -C "$T/repo" worktree add -q "$WT/builder-slot-$n" -b "agent/builder-s$n" main; done

fail() { echo "FAIL: $1"; exit 1; }
ran() { grep -qxF "$1" "$WARM_RAN_LOG"; }

# slot-1 is claimed by a live thread; slot-2 holds unpushed work
printf 'root123\t%s\tagent/builder-s1\n' "$WT/builder-slot-1" > "$HOME/.buzz/agents/builder/worktrees.tsv"
git -C "$WT/builder-slot-2" commit -q --allow-empty -m "unpushed"

WARM_FORCE=1 sh "$WARM" builder >/dev/null 2>&1
ran "$WT/builder-slot-0" || fail "did not warm the one free clean slot"
ran "$WT/builder-slot-1" && fail "warmed a slot a live thread is using"
ran "$WT/builder-slot-2" && fail "warmed a slot holding unpushed commits"
echo "ok: warms only the free, clean, fully-pushed slot"

# already warm at this main: second run must be a no-op
: > "$WARM_RAN_LOG"
WARM_FORCE=1 sh "$WARM" builder >/dev/null 2>&1
[ -s "$WARM_RAN_LOG" ] && fail "rewarmed a slot already at origin/main"
echo "ok: already-warm slot is left alone"

# main moves on: the slot is due again
echo change >> "$T/repo/a.txt"
git -C "$T/repo" commit -qam "move main"; git -C "$T/repo" push -q origin main
: > "$WARM_RAN_LOG"
WARM_FORCE=1 sh "$WARM" builder >/dev/null 2>&1
ran "$WT/builder-slot-0" || fail "did not rewarm after main moved"
echo "ok: rewarms once main moves"

# a dirty slot is never reset out from under anyone
: > "$WARM_RAN_LOG"
echo dirty >> "$WT/builder-slot-0/a.txt"
rm -f "$(git -C "$WT/builder-slot-0" rev-parse --absolute-git-dir)/agent-warmed-sha"
WARM_FORCE=1 sh "$WARM" builder >/dev/null 2>&1
ran "$WT/builder-slot-0" && fail "warmed a dirty slot"
[ -n "$(git -C "$WT/builder-slot-0" status --porcelain)" ] || fail "warmer destroyed uncommitted changes"
echo "ok: dirty slot untouched and its changes intact"

# no warm script in the repo: exit quietly, touch nothing
: > "$WARM_RAN_LOG"
git -C "$T/repo" rm -q tools/agent-warm-slot.sh; git -C "$T/repo" commit -qm drop; git -C "$T/repo" push -q origin main
WARM_FORCE=1 sh "$WARM" builder >/dev/null 2>&1 || fail "should exit 0 when the repo has no warm script"
[ -s "$WARM_RAN_LOG" ] && fail "ran something with no warm script present"
echo "ok: no-op when the repo defines no warm command"

rm -rf "$T"
echo "ALL PASS"
