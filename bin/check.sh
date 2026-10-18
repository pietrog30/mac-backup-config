#!/bin/bash
# Weekly: verify repository integrity, critical paths, size trend and Full Disk Access.
source "$HOME/.config/mac-backup/bin/env.sh"
mb_start check
mb_wait_lock 3600 || { log "could not get the lock within 1 h; skipping"; exit 0; }

OUT="$MB_STATE/check.last"; : >"$OUT"
problems=0
note() { echo "$*" | tee -a "$OUT"; }

# 1. Full Disk Access still granted to the runner
if mb_fda_ok; then note "fda: ok"; else note "fda: MISSING"; problems=$((problems + 1)); fi

# 2. Repository integrity; in the first week of the month also read back 5% of the data
args=()
(( 10#$(date +%d) <= 7 )) && args=(--read-data-subset=5%)
# (bash 3.2 on macOS: an empty array is "unbound" under set -u, hence the ${args[@]+...} form)
if restic check ${args[@]+"${args[@]}"} 2>&1 | tee -a "$OUT"; then note "check ${args[*]:-}: ok"
else note "check ${args[*]:-}: FAILED"; problems=$((problems + 1)); fi

# 3. Critical paths present in the latest snapshot (only those that exist on this Mac)
while IFS= read -r p; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    [[ -e "$HOME/$p" ]] || continue
    n="$(restic ls --host "$BACKUP_HOST" --json latest "$HOME/$p" 2>/dev/null | grep -c '"struct_type":"node"' || true)"
    if (( n == 0 )); then note "critical path MISSING from latest snapshot: ~/$p"; problems=$((problems + 1)); fi
done <"$MB_DIR/critical-paths.txt"
note "critical paths: checked"

# 4. Size trend of the latest snapshot vs the previous check (flags a >20% jump or drop)
size="$(restic stats --host "$BACKUP_HOST" --json latest 2>/dev/null | grep -Eo '"total_size":[0-9]+' | cut -d: -f2 || true)"
if [[ -n "$size" ]]; then
    prev="$(cat "$MB_STATE/last-size" 2>/dev/null || true)"
    note "latest snapshot size: $((size / 1048576)) MiB (previous: ${prev:+$((prev / 1048576)) MiB}${prev:-none})"
    if [[ -n "$prev" ]] && (( prev > 0 )); then
        change=$(( (size - prev) * 100 / prev ))
        if (( change > 20 || change < -20 )); then note "size changed ${change}% since last check"; problems=$((problems + 1)); fi
    fi
    echo "$size" >"$MB_STATE/last-size"
else
    note "could not read snapshot size"; problems=$((problems + 1))
fi

if (( problems > 0 )); then log "FAIL: $problems problem(s)"; mb_ping "$HC_CHECK_URL" /fail "$OUT"; exit 1; fi
log "ok"; mb_ping "$HC_CHECK_URL" "" "$OUT"
