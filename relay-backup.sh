#!/usr/bin/env bash
# Nightly backup of a docker-compose Buzz relay: pg_dump -Fc of the database and a tar of
# the MinIO volume, with SHA256SUMS, into $BACKUP_DEST/<YYYY-MM-DD>/. Keeps the newest
# $KEEP_DAYS dated folders. Secrets (.env, bot keys) are never copied.
#
# The folder is written under a dot-prefixed temp name in $BACKUP_DEST and renamed into
# place only once complete, so a sync client (OneDrive, Dropbox) never uploads a half
# dump as the real thing.
#
# Any failure posts to $ALERT_CHANNEL (and a macOS notification if that post fails too),
# then exits non-zero. A backup that fails quietly is worse than none.
#
#   BACKUP_DEST=~/backups/buzz ALERT_CHANNEL=<id> ALERT_KEY_FILE=~/bot.key relay-backup.sh
#   relay-backup.sh --dry-run      # print what would happen, write nothing
#
# Env:
#   BACKUP_DEST     required; parent folder for the dated backups
#   ALERT_CHANNEL   Buzz channel id for failure posts (unset: log + notification only)
#   ALERT_KEY_FILE  file holding the nsec that posts the alert
#   BUZZ_RELAY_URL  the relay to post to; launchd does not inherit it from your shell
#   PG_CONTAINER    default buzz-postgres     PG_USER / PG_DB  default buzz
#   MINIO_VOLUME    default buzz-minio-data   TAR_IMAGE        default alpine:latest
#   KEEP_DAYS       default 7
set -uo pipefail

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
DEST="${BACKUP_DEST:?set BACKUP_DEST}"
PG_CONTAINER="${PG_CONTAINER:-buzz-postgres}"
PG_USER="${PG_USER:-buzz}"
PG_DB="${PG_DB:-buzz}"
MINIO_VOLUME="${MINIO_VOLUME:-buzz-minio-data}"
TAR_IMAGE="${TAR_IMAGE:-alpine:latest}"
KEEP="${KEEP_DAYS:-7}"
DAY="$(date +%F)"
TMP="$DEST/.$DAY.partial"
OUT="$DEST/$DAY"

log() { echo "$(date '+%F %T') relay-backup: $*"; }

fail() {
  local msg="Relay backup FAILED on $(hostname -s) ($DAY): $*"
  log "$msg"
  [ "$DRY" = 1 ] && exit 1
  rm -rf "$TMP"
  if [ -n "${ALERT_CHANNEL:-}" ] && [ -r "${ALERT_KEY_FILE:-}" ] &&
     BUZZ_PRIVATE_KEY="$(cat "$ALERT_KEY_FILE")" buzz messages send \
       --channel "$ALERT_CHANNEL" --content "$msg" </dev/null >/dev/null 2>&1; then
    log "alert posted"
  else
    # ponytail: the relay may be down for the same reason the dump failed; a desktop
    # notification is the only fallback. Add email/push if this box runs headless.
    log "alert post failed, falling back to a notification"
    osascript -e "display notification \"$msg\" with title \"Relay backup failed\"" 2>/dev/null
  fi
  exit 1
}

[ -d "$DEST" ] || fail "destination $DEST does not exist"
command -v docker >/dev/null || fail "docker not on PATH"
docker inspect "$PG_CONTAINER" >/dev/null 2>&1 || fail "container $PG_CONTAINER not found (is docker up?)"
docker volume inspect "$MINIO_VOLUME" >/dev/null 2>&1 || fail "volume $MINIO_VOLUME not found"

# Dated folders past the newest $KEEP, counting the one this run writes.
old=$( { cd "$DEST" && ls -d 20[0-9][0-9]-[0-1][0-9]-[0-3][0-9] 2>/dev/null; echo "$DAY"; } | sort -ru | tail -n +"$((KEEP + 1))")
if [ "$DRY" = 1 ]; then
  log "dry run: would dump $PG_DB from $PG_CONTAINER and tar $MINIO_VOLUME into $OUT (via $TMP)"
  log "dry run: would prune: ${old:-nothing}"
  exit 0
fi

rm -rf "$TMP" && mkdir -p "$TMP" || fail "cannot create $TMP"

docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc "$PG_DB" > "$TMP/buzz.dump" ||
  fail "pg_dump of $PG_DB failed"
docker exec -i "$PG_CONTAINER" pg_restore --list < "$TMP/buzz.dump" >/dev/null ||
  fail "pg_dump output is not a readable archive"

# ponytail: tars the live volume; fine at this write rate. Use `mc mirror` if objects
# start changing during the run.
docker run --rm -v "$MINIO_VOLUME:/data:ro" "$TAR_IMAGE" tar czf - data > "$TMP/minio-data.tgz" ||
  fail "tar of volume $MINIO_VOLUME failed"

(cd "$TMP" && shasum -a 256 buzz.dump minio-data.tgz > SHA256SUMS) || fail "checksumming failed"

# Same-day rerun replaces that day's folder.
rm -rf "$OUT" && mv "$TMP" "$OUT" || fail "could not move backup into $OUT"
log "wrote $OUT ($(du -sh "$OUT" | cut -f1))"

for d in $old; do rm -rf "${DEST:?}/$d" && log "pruned $d"; done
