#!/bin/bash
# Idempotent bootstrap for one Mac.
#   ./install.sh           install restic, build the runner, create secrets.env, write LaunchAgents
#   ./install.sh --load    the above, then enable the schedules
#   ./install.sh --unload  disable the schedules
set -euo pipefail
MB_DIR="$HOME/.config/mac-backup"
cd "$(dirname "$0")"
[[ "$PWD" == "$MB_DIR" ]] || { echo "This repo must be cloned to $MB_DIR (it is at $PWD)."; exit 1; }

AGENTS="$HOME/Library/LaunchAgents"
LABEL=com.pietro.mac-backup
JOBS=(backup prune check restore-test)

unload() {
    for j in "${JOBS[@]}"; do launchctl bootout "gui/$(id -u)/$LABEL.$j" 2>/dev/null || true; done
}
if [[ "${1:-}" == --unload ]]; then unload; echo "Schedules disabled."; exit 0; fi

# 1. restic
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
command -v restic >/dev/null || brew install restic
mkdir -p state "$HOME/Library/Logs/mac-backup" "$AGENTS"
chmod +x bin/*.sh install.sh

# 2. the FDA runner
if [[ ! -x bin/mac-backup-runner || src/runner.c -nt bin/mac-backup-runner ]]; then
    clang -O2 -Wall -Wextra -o bin/mac-backup-runner src/runner.c
    codesign --force --sign - --identifier "$LABEL.runner" bin/mac-backup-runner
    echo ">> Runner (re)built. Grant it Full Disk Access:"
    echo "   System Settings > Privacy & Security > Full Disk Access > + > $MB_DIR/bin/mac-backup-runner"
fi

# 3. secrets
if [[ ! -f secrets.env ]]; then
    (umask 077; cp secrets.env.example secrets.env)
    echo ">> Created secrets.env: fill it from the Passwords app entry \"restic <host>\"."
fi
chmod 600 secrets.env

# 4. LaunchAgents
plist() {  # $1 job, $2 StartCalendarInterval XML
    cat >"$AGENTS/$LABEL.$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL.$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>$MB_DIR/bin/mac-backup-runner</string>
    <string>$1</string>
  </array>
  <key>StartCalendarInterval</key>
  $2
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mac-backup/launchd-$1.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mac-backup/launchd-$1.log</string>
</dict>
</plist>
PLIST
    plutil -lint -s "$AGENTS/$LABEL.$1.plist"
}
cal() { printf '<dict>'; while (( $# )); do printf '<key>%s</key><integer>%s</integer>' "$1" "$2"; shift 2; done; printf '</dict>'; }
plist backup       "$(cal Minute 17)"                                  # hourly at :17
plist prune        "$(cal Weekday 0 Hour 12 Minute 41)"                # Sundays 12:41
plist check        "$(cal Weekday 3 Hour 12 Minute 41)"                # Wednesdays 12:41
plist restore-test "<array>$(for m in 1 4 7 10; do cal Month $m Day 2 Hour 12 Minute 51; done)</array>"  # quarterly
echo "LaunchAgents written to $AGENTS."

if [[ "${1:-}" == --load ]]; then
    unload
    for j in "${JOBS[@]}"; do launchctl bootstrap "gui/$(id -u)" "$AGENTS/$LABEL.$j.plist"; done
    echo "Schedules enabled. Run a job now with: launchctl kickstart gui/$(id -u)/$LABEL.backup"
else
    echo "Schedules not enabled yet. When secrets.env is filled and the repo initialized: ./install.sh --load"
fi
