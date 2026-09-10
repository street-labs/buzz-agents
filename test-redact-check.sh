#!/usr/bin/env bash
# Verifies the commit-msg hook and the CI scan reject denylisted text and pass clean
# text. Run: bash test-redact-check.sh
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/hooks/commit-msg"
T=$(mktemp -d)
export BUZZ_DENYLIST_FILE="$T/denylist"
printf '%s\n' "# comment line" "" "acmecorp" "example\.com" > "$BUZZ_DENYLIST_FILE"
fail() { echo "FAIL: $1"; exit 1; }

printf 'Fix the widget cache\n' > "$T/ok.msg"
sh "$HOOK" "$T/ok.msg" 2>/dev/null || fail "clean message was rejected"
echo "ok: clean commit message passes"

printf 'Fix the widget cache\n\nSeen on acmecorp-mobile.\n' > "$T/bad.msg"
sh "$HOOK" "$T/bad.msg" 2>/dev/null && fail "denylisted commit message was accepted"
echo "ok: denylisted commit message rejected"

printf 'Ping AcMeCorp again\n' > "$T/case.msg"
sh "$HOOK" "$T/case.msg" 2>/dev/null && fail "match should be case-insensitive"
echo "ok: match is case-insensitive"

printf 'A comment-only denylist must not match\n' > "$T/c.msg"
printf '%s\n' "# acmecorp" > "$BUZZ_DENYLIST_FILE"
sh "$HOOK" "$T/c.msg" 2>/dev/null || fail "commented-out pattern was applied"
echo "ok: comments and blank lines ignored"

# The CI step's scan, same logic over title + body + commit subjects.
scan() {
  local hay="$1" list="$2" n=0 bad=0
  while IFS= read -r pat; do
    n=$((n + 1)); case "$pat" in ''|'#'*) continue ;; esac
    grep -qiE "$pat" <<<"$hay" && bad=1
  done <<< "$list"
  return $bad
}
LIST=$'# c\nacmecorp\nexample\\.com'
scan "Retry the queue"$'\n'"Nothing to see" "$LIST" || fail "clean PR text was rejected"
echo "ok: clean PR title/body passes"
scan "Retry the queue"$'\n'"Broke on acmecorp's repo" "$LIST" && fail "denylisted PR body was accepted"
echo "ok: denylisted PR body rejected"
scan "acmecorp rollout"$'\n'"body is fine" "$LIST" && fail "denylisted PR title was accepted"
echo "ok: denylisted PR title rejected"

rm -rf "$T"
echo "ALL PASS"
