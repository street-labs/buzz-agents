#!/usr/bin/env bash
# Tests for drop_stale_build in agent-watcher.sh: a recycled slot loses its build dir
# only when the main it last started from is more than SLOT_BUILD_STALE_DAYS behind.
set -u
cd "$(dirname "$0")"
fail() { echo "FAIL: $1"; exit 1; }
eval "$(sed -n '/^drop_stale_build() {/,/^}/p' agent-watcher.sh)"
AGENT_NAME=test SLOT_BUILD_STALE_DAYS=3
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git init -q "$T/slot-1"
c() { GIT_COMMITTER_DATE="$1" git -C "$T/slot-1" commit -q --allow-empty -m "$1" --date "$1"; git -C "$T/slot-1" rev-parse HEAD; }
old="$(c 2026-09-23T12:00:00)"; near="$(c 2026-10-14T12:00:00)"; tip="$(c 2026-10-16T12:00:00)"
SLOT_BUILD_DIR="$T/dd/{slot}/Build"
gitdir="$T/slot-1/.git"

mkdir -p "$T/dd/slot-1/Build"; echo "$near" > "$gitdir/agent-base-sha"
drop_stale_build "$T/slot-1" "$tip" 2>/dev/null
[ -d "$T/dd/slot-1/Build" ] || fail "2 days behind dropped the build"

echo "$old" > "$gitdir/agent-base-sha"
drop_stale_build "$T/slot-1" "$tip" 2>/dev/null
[ ! -d "$T/dd/slot-1/Build" ] || fail "23 days behind kept the build"

# No marker: falls back to HEAD's merge-base, here the tip itself, so nothing goes.
mkdir -p "$T/dd/slot-1/Build"; rm -f "$gitdir/agent-base-sha"
drop_stale_build "$T/slot-1" "$tip" 2>/dev/null
[ -d "$T/dd/slot-1/Build" ] || fail "no marker, fresh HEAD dropped the build"

echo "$old" > "$gitdir/agent-base-sha"; SLOT_BUILD_DIR=""
drop_stale_build "$T/slot-1" "$tip" 2>/dev/null
[ -d "$T/dd/slot-1/Build" ] || fail "unset SLOT_BUILD_DIR dropped the build"
echo "stale-build: all tests passed"
