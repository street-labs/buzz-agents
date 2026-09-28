#!/usr/bin/env bash
# Compile every embedded Python payload in agent-watcher.sh.
#
# Python embedded in a single-quoted bash string breaks silently when the python
# itself contains a single quote: bash ends the string early and python receives
# a truncated expression. This has shipped three times (the rung-2 arbiter prompt
# in #16, SALON_FILTER in #17/#20), and `bash -n` cannot catch any of them because
# the shell syntax stays valid - only the payload is mangled.
#
# This extracts each NAME='...python...' assignment the way bash actually expands
# it, then compiles the result.
set -u
cd "$(dirname "$0")"

target="${1:-agent-watcher.sh}"
rc=0
found=0

# Names of single-quoted heredoc-free python payloads assigned as NAME='
names="$(grep -n "^[A-Z_]*=''*$" "$target" 2>/dev/null | sed 's/:.*//')"
names="$(grep -oE "^[A-Z_]+='$" "$target" | tr -d "='")"

for name in $names; do
  # Pull the assignment block and source it so bash performs its own quote
  # handling, exactly as the watcher does at runtime.
  start="$(grep -n "^${name}='$" "$target" | head -1 | cut -d: -f1)"
  [ -n "$start" ] || continue
  end="$(awk -v s="$start" "NR>s && /^'\$/ {print NR; exit}" "$target")"
  [ -n "$end" ] || { echo "WARN: ${name}: no closing quote found"; continue; }

  payload="$(sed -n "${start},${end}p" "$target" > /tmp/_ep_block.sh; bash -c ". /tmp/_ep_block.sh; printf '%s' \"\$$name\"")"

  # Only check payloads that actually look like python.
  case "$payload" in
    *"import "*|*"def "*|*"json."*) : ;;
    *) continue ;;
  esac

  found=$((found + 1))
  if printf '%s' "$payload" | python3 -c 'import sys, ast; ast.parse(sys.stdin.read())' 2>/tmp/_ep_err; then
    echo "ok: $name compiles"
  else
    echo "FAIL: $name does not compile as bash delivers it:"
    sed 's/^/    /' /tmp/_ep_err
    echo "    hint: the payload is inside a single-quoted bash string; remove"
    echo "    single quotes from the python (use double quotes or concatenation)."
    rc=1
  fi
done

rm -f /tmp/_ep_block.sh /tmp/_ep_err
[ "$found" -gt 0 ] || { echo "FAIL: no python payloads found in $target - check the extractor"; exit 1; }
echo "checked $found embedded python payload(s)"
exit $rc
