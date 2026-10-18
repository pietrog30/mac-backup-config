#!/bin/bash
# Hourly: back up $HOME to this Mac's restic repository.
source "$HOME/.config/mac-backup/bin/env.sh"
mb_start backup

if ! mb_try_lock; then log "another job is running; skipping this run"; exit 0; fi
if mb_low_battery; then log "on battery below 20%; skipping this run"; exit 0; fi

OUT="$MB_STATE/backup.last"
mb_ping "$HC_BACKUP_URL" /start

if ! mb_fda_ok; then
    echo "Full Disk Access is missing for mac-backup-runner (System Settings > Privacy & Security > Full Disk Access)." >"$OUT"
    cat "$OUT"; mb_ping "$HC_BACKUP_URL" /fail "$OUT"; exit 1
fi

restic unlock >/dev/null 2>&1 || true   # clears only stale locks, e.g. after sleep or shutdown

excl=(--exclude-file "$MB_DIR/excludes.txt")
[[ -f "$MB_DIR/hosts/$BACKUP_HOST.excludes" ]] && excl+=(--exclude-file "$MB_DIR/hosts/$BACKUP_HOST.excludes")

set +e
restic -o "s3.connections=$MB_S3_CONNECTIONS" backup "$HOME" \
    --host "$BACKUP_HOST" --tag auto \
    --one-file-system --no-scan \
    --exclude-caches --exclude-if-present .nobackup \
    "${excl[@]}" >"$OUT" 2>&1
rc=$?
set -e
cat "$OUT"

case $rc in
    0)
        log "ok"; mb_ping "$HC_BACKUP_URL" "" "$OUT" ;;
    3)  # snapshot written, but some files could not be read
        n="$(grep -c '^error: ' "$OUT" || true)"
        if (( n <= MB_MAX_READ_ERRORS )); then
            log "ok with $n unreadable files"; mb_ping "$HC_BACKUP_URL" "" "$OUT"
        else
            log "FAIL: $n unreadable files (limit $MB_MAX_READ_ERRORS)"; mb_ping "$HC_BACKUP_URL" /fail "$OUT"; exit 1
        fi ;;
    *)
        log "FAIL: restic exit $rc"; mb_ping "$HC_BACKUP_URL" /fail "$OUT"; exit "$rc" ;;
esac
