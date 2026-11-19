#!/usr/bin/env bash
# Verifies relay-backup.sh: writes a dated folder with checksums, prunes past KEEP_DAYS,
# leaves no temp folder, dry run writes nothing, and a failure posts an alert.
# Uses stub docker/buzz/osascript. Run: bash test-relay-backup.sh
set -u
S="$(cd "$(dirname "$0")" && pwd)/relay-backup.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
mkdir -p "$T/bin" "$T/dest"
cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
[ -n "${STUB_FAIL:-}" ] && case "$*" in *pg_dump*) exit 1;; esac
case "$*" in *pg_dump*) echo dump;; *tar*) echo tar;; *pg_restore*) cat >/dev/null;; esac
STUB
printf '#!/bin/sh\necho "$@" >> "%s/posted"\n' "$T" > "$T/bin/buzz"
printf '#!/bin/sh\n' > "$T/bin/osascript"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" BACKUP_DEST="$T/dest" KEEP_DAYS=3 ALERT_CHANNEL=chan ALERT_KEY_FILE="$T/key"
echo nsec > "$T/key"
for d in 2020-01-01 2020-01-02 2020-01-03 2020-01-04; do mkdir "$T/dest/$d"; done
today=$(date +%F)

bash "$S" --dry-run >/dev/null || fail "dry run exited non-zero"
[ "$(ls -A "$T/dest" | wc -l | tr -d ' ')" = 4 ] || fail "dry run wrote something"
echo "ok: dry run writes nothing"

bash "$S" >/dev/null || fail "backup exited non-zero"
[ -s "$T/dest/$today/buzz.dump" ] && [ -s "$T/dest/$today/minio-data.tgz" ] || fail "missing files"
(cd "$T/dest/$today" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "checksums do not verify"
echo "ok: dated folder with verifying SHA256SUMS"
[ "$(ls "$T/dest" | tr '\n' ' ')" = "2020-01-03 2020-01-04 $today " ] || fail "prune kept: $(ls "$T/dest")"
echo "ok: keeps newest KEEP_DAYS including today"
[ -z "$(ls -A "$T/dest" | grep '^\.')" ] || fail "temp folder left behind"
echo "ok: no temp folder left"

STUB_FAIL=1 bash "$S" >/dev/null 2>&1 && fail "failed dump exited zero"
grep -q "FAILED" "$T/posted" || fail "no alert posted"
[ -s "$T/dest/$today/buzz.dump" ] || fail "failed run clobbered the good backup"
echo "ok: failure posts an alert and keeps the last good backup"
