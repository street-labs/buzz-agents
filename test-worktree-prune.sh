#!/usr/bin/env bash
# Exercises the slot-pruning fixes: orphan slot-dir sweep (fix 1) and
# stale-reclaim of tracked slots whose thread is dead (fix 3).
# Run: bash test-worktree-prune.sh
set -u
WATCHER="$(cd "$(dirname "$0")" && pwd)/agent-watcher.sh"
T=/tmp/prunetest
rm -rf $T/origin $T/repo $T/repo-worktrees $T/state; mkdir -p $T/state $T/state/workers
git init -q --bare $T/origin
git clone -q $T/origin $T/repo 2>/dev/null
cd $T/repo
git config user.email t@t.t; git config user.name t
echo hi > a.txt; echo "build/" > .gitignore; git add -A; git commit -qm init; git branch -M main; git push -q origin main

AGENT_NAME=builder
AGENT_REPO=$T/repo
WORKTREES=$T/state/worktrees.tsv; touch "$WORKTREES"
ARCHIVE=$T/state/slot-archive.tsv; touch "$ARCHIVE"
WORKERS=$T/state/workers

get_worktree() { flock "$WORKTREES" awk -F'\t' -v r="$1" '$1==r{print $2; exit}' "$WORKTREES"; }
set_worktree() {
  local tmp; tmp="$(mktemp)"
  ( flock 200
    awk -F'\t' -v r="$1" '$1!=r' "$WORKTREES" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
    mv "$tmp" "$WORKTREES"
  ) 200>"$WORKTREES.lock"
}
# functions under test, extracted verbatim
eval "$(sed -n '/^SLOT_STALE_DAYS=/p;/^PRUNE_INTERVAL=/p;/^slot_is_stale() {/,/^}/p;/^tracked_slot_root() {/,/^}/p;/^tracked_slot_thread_alive() {/,/^}/p;/^claim_free_slot() {/,/^}/p;/^reserve_slot() {/,/^}/p;/^sweep_orphan_slot_dirs() {/,/^}/p' "$WATCHER")"

fail() { echo "FAIL: $1"; exit 1; }
B=$T/repo-worktrees

# --- Fix 1: orphan slot dirs (no row) are swept back to claimable ----------
orphan=$B/builder-slot-0
( cd "$AGENT_REPO" && git worktree add -q "$orphan" -b agent/builder-orphan origin/main ) || fail "setup: worktree add"
# no row in $WORKTREES names it; it is clean with nothing unpushed
echo stray > "$orphan/untracked.txt"   # uncommitted dirt: must NOT be reset
sweep_orphan_slot_dirs >/dev/null 2>&1
[ -f "$orphan/untracked.txt" ] || fail "sweep reset an orphan holding uncommitted work"
echo "ok: dirty orphan left alone"
rm "$orphan/untracked.txt"
git -C "$orphan" commit -q --allow-empty -m "unpushed orphan commit"
sweep_orphan_slot_dirs >/dev/null 2>&1
[ "$(git -C "$orphan" log --oneline origin/main..HEAD | wc -l)" -ge 1 ] || fail "sweep destroyed unpushed commits"
echo "ok: orphan with unpushed commits left alone"
git -C "$orphan" reset -q --hard origin/main
out="$(sweep_orphan_slot_dirs 2>&1)"
[ -z "$(git -C "$orphan" status --porcelain)" ] || fail "clean orphan was not swept"
echo "$out" | grep -q "swept orphan slot dir" || fail "sweep did not report the orphan"
echo "ok: clean orphan swept and reset"
( cd "$AGENT_REPO" && git worktree remove --force "$orphan" >/dev/null 2>&1 )  # out of the way for the next section

# --- Fix 3: tracked slot with a dead thread is reclaimable after idle ------
tracked=$B/builder-slot-1
( cd "$AGENT_REPO" && git worktree add -q "$tracked" -b agent/builder-tracked origin/main ) || fail "setup: worktree add 2"
set_worktree threadroot0001 "$tracked" agent/builder-tracked
# live thread -> NOT reclaimable even when stale
echo $$ > "$WORKERS/root-threadroot0001.pid"
git -C "$tracked" commit -q --allow-empty -m "held work"
find "$tracked" -type f -not -path '*/.git/*' -exec touch -t 202001010000 {} + 2>/dev/null
r=$(claim_free_slot "$B" newroot00001 2>/dev/null)
[ "$r" != "$tracked" ] || fail "stale tracked slot reclaimed while its thread is still live"
echo "ok: tracked slot with a live thread not reclaimed"
# kill the thread -> now reclaimable
rm -f "$WORKERS/root-threadroot0001.pid"
r=$(claim_free_slot "$B" newroot00001 2>/dev/null)
[ "$r" = "$tracked" ] || fail "stale tracked slot with a dead thread not reclaimed (got $r)"
[ "$(get_worktree threadroot0001)" = "" ] || fail "old row survived the reclaim"
[ "$(get_worktree newroot00001)" = "$tracked" ] || fail "new row not written"
git -C "$tracked" rev-parse --verify agent/builder-tracked >/dev/null 2>&1 || fail "reclaim deleted the branch holding tracked work"
echo "ok: tracked slot reclaimed after thread death, row migrated, branch preserved"

# thread that died long ago but whose slot saw recent activity is not reclaimed
echo fresh > "$tracked/recent.txt"   # recent activity: no longer stale
r2=$(claim_free_slot "$B" newroot00002 2>/dev/null)
[ "$r2" != "$tracked" ] || fail "fresh tracked slot reclaimed"
echo "ok: tracked slot with recent activity not reclaimed"

echo "ALL PASS"
