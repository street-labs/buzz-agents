#!/usr/bin/env bash
# Exercises claim_free_slot/create_worktree from agent-watcher.sh against a scratch
# repo. Run: bash test-worktree-slots.sh
set -u
WATCHER="$(cd "$(dirname "$0")" && pwd)/agent-watcher.sh"
T=/tmp/slottest
rm -rf $T/origin $T/repo $T/repo-worktrees $T/state; mkdir -p $T/state
git init -q --bare $T/origin
git clone -q $T/origin $T/repo 2>/dev/null
cd $T/repo
git config user.email t@t.t; git config user.name t
echo hi > a.txt; echo "build/" > .gitignore; git add -A; git commit -qm init; git branch -M main; git push -q origin main

AGENT_NAME=builder
AGENT_REPO=$T/repo
WORKTREES=$T/state/worktrees.tsv; touch "$WORKTREES"
ARCHIVE=$T/state/slot-archive.tsv; touch "$ARCHIVE"

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
eval "$(sed -n '/^archive_slot() {/,/^}/p;/^resurrect_branch() {/,/^}/p;/^SLOT_STALE_DAYS=/p;/^slot_is_stale() {/,/^}/p;/^claim_free_slot() {/,/^}/p' "$WATCHER")"
eval "$(sed -n '/^create_worktree() {/,/^}/p' "$WATCHER")"

fail() { echo "FAIL: $1"; exit 1; }

w1=$(create_worktree aaaaaaaa11111111 2>/dev/null)
[ "$w1" = "$T/repo-worktrees/builder-slot-0" ] || fail "first slot, got $w1"
mkdir -p "$w1/build"; echo artifact > "$w1/build/warm.o"   # gitignored build output

w2=$(create_worktree bbbbbbbb22222222 2>/dev/null)
[ "$w2" = "$T/repo-worktrees/builder-slot-1" ] || fail "second thread must not steal a live slot, got $w2"
echo "ok: live slot not stolen, new slot cut"

# release slot 0 the way cleanup_worktree does
git -C "$w1" reset --hard origin/main >/dev/null 2>&1; git -C "$w1" clean -fd >/dev/null 2>&1
tmp=$(mktemp); awk -F'\t' '$1!="aaaaaaaa11111111"' "$WORKTREES" > "$tmp"; mv "$tmp" "$WORKTREES"

w3=$(create_worktree cccccccc33333333 2>/dev/null)
[ "$w3" = "$w1" ] || fail "should have recycled slot-0, got $w3"
[ -f "$w1/build/warm.o" ] || fail "recycling destroyed the gitignored build output"
[ "$(git -C "$w3" branch --show-current)" = "agent/builder-cccccccc" ] || fail "wrong branch after recycle"
echo "ok: slot recycled, build output survived, branch reset"

# a slot holding unpushed commits must never be reclaimed
git -C "$w2" commit -q --allow-empty -m "unpushed work"
tmp=$(mktemp); awk -F'\t' '$1!="bbbbbbbb22222222"' "$WORKTREES" > "$tmp"; mv "$tmp" "$WORKTREES"
w4=$(create_worktree dddddddd44444444 2>/dev/null)
[ "$w4" != "$w2" ] || fail "reclaimed a slot holding unpushed commits"
echo "ok: unpushed work not reclaimed (got $w4)"

# dirty tree must never be reclaimed
echo dirty >> "$w4/a.txt"
tmp=$(mktemp); awk -F'\t' '$1!="dddddddd44444444"' "$WORKTREES" > "$tmp"; mv "$tmp" "$WORKTREES"
w5=$(create_worktree eeeeeeee55555555 2>/dev/null)
[ "$w5" != "$w4" ] || fail "reclaimed a dirty slot"
echo "ok: dirty slot not reclaimed (got $w5)"
# A stale slot holding unpushed commits IS reclaimed, and the work survives.
# w2 already carries the unpushed "unpushed work" commit from the case above.
old_branch=$(git -C "$w2" branch --show-current)
old_sha=$(git -C "$w2" rev-parse HEAD)
echo "uncommitted too" >> "$w2/a.txt"
find "$w2" -type f -not -path '*/.git/*' -exec touch -t 202001010000 {} + 2>/dev/null
w6=$(create_worktree ffffffff66666666 2>/dev/null)
[ "$w6" = "$w2" ] || fail "stale slot with unpushed work should be reclaimed, got $w6"
git -C "$w2" rev-parse --verify "$old_branch" >/dev/null 2>&1 || fail "reclaim deleted the branch holding unpushed work"
git -C "$w2" merge-base --is-ancestor "$old_sha" "$old_branch" || fail "reclaim lost the unpushed commit"
git -C "$w2" log -1 --format=%s "$old_branch" | grep -q "^WIP: parked by watcher" || fail "uncommitted changes were not parked"
echo "ok: stale slot reclaimed, commits and uncommitted work preserved on $old_branch"

# A thread that comes back after its slot was recycled lands on its own branch.
r=99999999aaaaaaaa
w7=$(create_worktree $r 2>/dev/null)
echo "thread work" > "$w7/feature.txt"
git -C "$w7" add -A && git -C "$w7" commit -qm "thread work"
git -C "$w7" push -q origin "agent/builder-99999999" 2>/dev/null
kept_sha=$(git -C "$w7" rev-parse HEAD)
archive_slot "$r" "$w7" "agent/builder-99999999"
tmp=$(mktemp); awk -F'\t' -v r="$r" '$1!=r' "$WORKTREES" > "$tmp"; mv "$tmp" "$WORKTREES"
git -C "$w7" checkout -q --detach 2>/dev/null   # free the branch, as a release would

w8=$(create_worktree $r 2>/dev/null)
[ "$(git -C "$w8" rev-parse HEAD)" = "$kept_sha" ] || fail "resurrected thread did not land on its own commit"
[ -f "$w8/feature.txt" ] || fail "resurrected thread lost its file"
echo "ok: thread resurrected onto its own branch at $kept_sha"

# A worktree can be deleted while its row survives - the external reaper sweeps
# clean ones, and reviewer worktrees hold nothing by construction. The thread must
# get a live directory back, not the dead path: a resume cds into it and dies
# before the harness starts.
r2=77777777bbbbbbbb
w9=$(create_worktree $r2 2>/dev/null)
git -C "$AGENT_REPO" worktree remove --force "$w9" >/dev/null 2>&1 || fail "could not remove $w9"
[ "$(get_worktree $r2)" = "$w9" ] || fail "row should still point at the removed path"
w10=$(create_worktree $r2 2>/dev/null)
[ -d "$w10" ] || fail "handed back a path that does not exist: $w10"
[ "$(get_worktree $r2)" = "$w10" ] || fail "row not repointed at the live worktree"
echo "ok: deleted worktree replaced with a live one ($w10)"

echo "ALL PASS"
