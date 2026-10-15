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
eval "$(sed -n '/^archive_slot() {/,/^}/p;/^resurrect_branch() {/,/^}/p;/^SLOT_STALE_DAYS=/p;/^thread_alive() {/,/^}/p;/^slot_is_stale() {/,/^}/p;/^reserve_slot() {/,/^}/p;/^claim_new_slot() {/,/^}/p;/^del_worktree() {/,/^}/p;/^claim_free_slot() {/,/^}/p;/^sweep_orphan_slots() {/,/^}/p' "$WATCHER")"
# thread_alive reads $WORKERS/<root>.pid; no workers dir here means every thread is dead.
WORKERS=$T/state/workers; mkdir -p "$WORKERS"
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

# Concurrency: two watchers claiming in the same poll cycle must get different
# slots. This is the TOCTOU that put two roots onto coffee-shop-slot-6 at once.
rA=aaa1bbbb; rB=bbb2cccc
create_worktree $rA >/dev/null 2>&1 & p1=$!
create_worktree $rB >/dev/null 2>&1 & p2=$!
wait $p1 $p2
a="$(get_worktree $rA)"; b="$(get_worktree $rB)"
[ -n "$a" ] && [ -n "$b" ] || fail "concurrent claims returned empty ($a / $b)"
[ -d "$a" ] && [ -d "$b" ] || fail "concurrent claims handed back non-directories ($a / $b)"
[ "$a" != "$b" ] || fail "concurrent claims got the same slot: $a"
echo "ok: concurrent claims got distinct slots ($a / $b)"

# A tracked slot whose thread is DEAD (no live worker pid) and gone quiet IS
# reclaimable at the stale tier; the dead thread's row is evicted in the same claim.
r3=deadbeefdeadbeef
w11=$(create_worktree $r3 2>/dev/null)
[ -n "$(flock "$WORKTREES" awk -F'\t' -v r="$r3" '$1==r' "$WORKTREES")" ] || fail "no row for $r3"
echo tracked-change >> "$w11/a.txt"; git -C "$w11" add -A; git -C "$w11" commit -qm "tracked work"
find "$w11" -type f -not -path '*/.git/*' -exec touch -t 202001010000 {} + 2>/dev/null
w12=$(create_worktree cafebabecafebabe 2>/dev/null)
[ "$w12" = "$w11" ] || fail "stale tracked slot with dead thread not reclaimed, got $w12"
flock "$WORKTREES" grep -q "$r3" "$WORKTREES" && fail "dead thread's row survived the reclaim"
flock "$WORKTREES" grep -q cafebabecafebabe "$WORKTREES" || fail "claimer's row not written"
# dead thread's committed work survives on its branch
git -C "$w12" rev-parse --verify "agent/builder-deadbeef" >/dev/null 2>&1 || fail "dead thread's branch lost"
git -C "$w12" log -1 --format=%s "agent/builder-deadbeef" | grep -q "tracked work" || fail "dead thread's commit lost"
echo "ok: tracked slot with dead thread reclaimed, row evicted, work kept on its branch"

# ...but a tracked slot whose thread has a LIVE worker pid is never touched.
r4=livebeeflivebeef
w13=$(create_worktree $r4 2>/dev/null)
echo $$ > "$WORKERS/root-$r4.pid"
echo live-change >> "$w13/a.txt"; git -C "$w13" add -A; git -C "$w13" commit -qm "live work"
find "$w13" -type f -not -path '*/.git/*' -exec touch -t 202001010000 {} + 2>/dev/null
w14=$(create_worktree feedfacefeedface 2>/dev/null)
[ "$w14" = "$w13" ] && fail "stole a slot from a live thread"
rm -f "$WORKERS/root-$r4.pid"
echo "ok: live thread's tracked slot not touched (got $w14)"

# Orphan sweep: a slot dir with NO worktrees.tsv row is torn down; dirty work is
# parked on the branch; dirs with a row (tracked or reserving) are untouched.
r5=0rphan0000aaaa
w15=$(create_worktree $r5 2>/dev/null)
echo orphan-work > "$w15/orphan.txt"   # uncommitted, should be parked
w16=$(create_worktree keepme00112233 2>/dev/null)   # stays tracked, must survive
flock "$WORKTREES" awk -F'\t' -v r="$r5" '$1!=r' "$WORKTREES" > "$tmp"; mv "$tmp" "$WORKTREES"
branch15=$(git -C "$w15" branch --show-current)
sweep_orphan_slots >/dev/null 2>&1
[ -d "$w15" ] && fail "orphan slot dir not torn down"
[ -d "$w16" ] || fail "sweep tore down a tracked slot"
flock "$WORKTREES" grep -q keepme00112233 "$WORKTREES" || fail "sweep removed a tracked row"
git -C "$AGENT_REPO" rev-parse --verify "$branch15" >/dev/null 2>&1 || fail "orphan sweep lost the branch"
git -C "$AGENT_REPO" log -1 --format=%s "$branch15" | grep -q "WIP: parked by watcher orphan sweep" || fail "orphan sweep did not park uncommitted work"
git -C "$AGENT_REPO" cat-file -p "$branch15:orphan.txt" | grep -q orphan-work || fail "parked orphan file missing"
echo "ok: orphan slot swept, uncommitted work parked on $branch15, tracked slots untouched"

echo "ALL PASS"
