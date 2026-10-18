# shellcheck shell=bash
# Sourced by every job script: loads secrets and host settings, defines helpers.
set -euo pipefail

MB_DIR="$HOME/.config/mac-backup"
MB_STATE="$MB_DIR/state"
MB_LOGS="$HOME/Library/Logs/mac-backup"
MB_MAX_READ_ERRORS="${MB_MAX_READ_ERRORS:-25}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
umask 077
mkdir -p "$MB_STATE" "$MB_LOGS"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${MB_JOB:-?}" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# --- secrets + host settings
SECRETS="$MB_DIR/secrets.env"
[[ -f "$SECRETS" ]] || die "missing $SECRETS (copy secrets.env.example)"
perm="$(stat -f '%Lp' "$SECRETS")"
[[ "$perm" == 600 || "$perm" == 400 ]] || die "$SECRETS must be mode 600 (is $perm)"
if grep -q REPLACE_ME "$SECRETS"; then die "$SECRETS still has REPLACE_ME placeholders"; fi
set -a
# shellcheck disable=SC1090
source "$SECRETS"
set +a
: "${BACKUP_HOST:?}" "${RESTIC_PASSWORD:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
: "${HC_BACKUP_URL:?}" "${HC_CHECK_URL:?}"
HOST_ENV="$MB_DIR/hosts/$BACKUP_HOST.env"
[[ -f "$HOST_ENV" ]] || die "no host file $HOST_ENV"
set -a
# shellcheck disable=SC1090
source "$HOST_ENV"
set +a
: "${RESTIC_REPOSITORY:?}"
# Pack size stays at restic's default (16 MiB): B2 is slow per connection, so many small packs
# uploaded in parallel beat a few large ones (64 MiB made hourly runs take 8+ minutes).
MB_S3_CONNECTIONS="${MB_S3_CONNECTIONS:-16}"        # parallel uploads; B2 is slow per connection, restic defaults to 5

# --- logging: append to ~/Library/Logs/mac-backup/<job>.log, rotate at 5 MB
mb_start() {
    MB_JOB="$1"
    local logf="$MB_LOGS/$MB_JOB.log"
    if [[ -f "$logf" ]] && (( $(stat -f %z "$logf") > 5242880 )); then mv -f "$logf" "$logf.1"; fi
    if [[ -t 1 ]]; then exec > >(tee -a "$logf") 2>&1; else exec >>"$logf" 2>&1; fi
    log "start (host=$BACKUP_HOST pid=$$)"
}

# --- one job at a time per Mac (macOS has no flock(1); mkdir is atomic)
MB_LOCK="$MB_STATE/lock"
mb_try_lock() {
    if mkdir "$MB_LOCK" 2>/dev/null; then
        echo $$ >"$MB_LOCK/pid"
        trap 'rm -rf "$MB_LOCK"' EXIT
        return 0
    fi
    local pid; pid="$(cat "$MB_LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    log "removing stale lock (pid ${pid:-unknown})"
    rm -rf "$MB_LOCK"
    mb_try_lock
}
mb_wait_lock() {  # $1 = max seconds to wait
    local waited=0
    until mb_try_lock; do
        (( waited >= $1 )) && return 1
        sleep 60; waited=$((waited + 60))
    done
}

# --- healthchecks.io ping: mb_ping <base-url> <""|/start|/fail> [body-file]
mb_ping() {
    local url="$1$2"
    if [[ -n "${3:-}" && -f "$3" ]]; then
        tail -c 20000 "$3" | curl -fsS -m 15 --retry 3 -o /dev/null --data-binary @- "$url" || log "ping failed: $2"
    else
        curl -fsS -m 15 --retry 3 -o /dev/null "$url" || log "ping failed: $2"
    fi
}

# --- Full Disk Access probe: the user TCC database is readable only with FDA
mb_fda_ok() {
    head -c 1 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1
}

# --- true when running on battery below 20% (always false on a desktop Mac)
mb_low_battery() {
    local b pct
    b="$(pmset -g batt 2>/dev/null)" || return 1
    grep -q "Battery Power" <<<"$b" || return 1
    pct="$(grep -Eo '[0-9]+%' <<<"$b" | head -1 | tr -d %)"
    [[ -n "$pct" ]] && (( pct < 20 ))
}
