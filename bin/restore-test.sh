#!/bin/bash
# Quarterly: restore one random small critical folder from the latest snapshot and verify it.
source "$HOME/.config/mac-backup/bin/env.sh"
mb_start restore-test
mb_wait_lock 3600 || { log "could not get the lock within 1 h; skipping"; exit 0; }

OUT="$MB_STATE/restore-test.last"; : >"$OUT"
candidates=()
while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ -d "$HOME/$p" ]] || continue
    (( $(du -sk "$HOME/$p" 2>/dev/null | cut -f1) < 512000 )) && candidates+=("$p")   # < 500 MB
done <"$MB_DIR/critical-paths.txt"
(( ${#candidates[@]} > 0 )) || die "no restore candidates"
pick="${candidates[RANDOM % ${#candidates[@]}]}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mac-backup-restore.XXXXXX")"
cleanup() { rm -rf "$tmp" "$MB_LOCK"; }
trap cleanup EXIT

echo "restoring ~/$pick to $tmp" | tee -a "$OUT"
set +e
restic restore latest --host "$BACKUP_HOST" --target "$tmp" --include "$HOME/$pick" --verify >>"$OUT" 2>&1
rc=$?
set -e
cat "$OUT"
if (( rc != 0 )) || [[ ! -e "$tmp$HOME/$pick" ]]; then
    log "FAIL: restore of ~/$pick (exit $rc)"; mb_ping "$HC_CHECK_URL" /fail "$OUT"; exit 1
fi
files="$(find "$tmp$HOME/$pick" -type f | wc -l | tr -d ' ')"
changed="$( { diff -rq "$tmp$HOME/$pick" "$HOME/$pick" 2>/dev/null || true; } | wc -l | tr -d ' ')"  # diff exits 1 on differences
log "ok: restored and verified $files files of ~/$pick ($changed differ from live, expected for files changed since the snapshot)"
