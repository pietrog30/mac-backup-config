#!/bin/bash
# Weekly: apply the retention policy and delete unreferenced data.
source "$HOME/.config/mac-backup/bin/env.sh"
mb_start prune
mb_wait_lock 3600 || { log "could not get the lock within 1 h; skipping"; exit 0; }

OUT="$MB_STATE/prune.last"
set +e
restic forget --host "$BACKUP_HOST" \
    --keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 \
    --prune >"$OUT" 2>&1
rc=$?
set -e
cat "$OUT"
if (( rc != 0 )); then log "FAIL: restic exit $rc"; mb_ping "$HC_CHECK_URL" /fail "$OUT"; exit "$rc"; fi
log "ok"
