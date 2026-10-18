#!/bin/bash
# Record what software is installed, inside the home folder, so backups capture what to reinstall.
# Called weekly by check.sh; safe to run by hand; needs no secrets. Never fails its caller.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
D="$HOME/.config/mac-backup/state/inventory"
mkdir -p "$D"
ok=0; failed=()

record() {  # record <file> <command...>: replace <file> only if the command succeeds
    local name="$1"; shift
    if "$@" >"$D/$name.tmp" 2>/dev/null; then mv -f "$D/$name.tmp" "$D/$name"; ok=$((ok + 1))
    else rm -f "$D/$name.tmp"; failed+=("$name"); fi
}
apps() {
    ls -1 /Applications
    if [[ -d "$HOME/Applications" ]]; then ls -1 "$HOME/Applications" | sed 's|^|~/Applications/|'; fi
}

record macos.txt sw_vers
record applications.txt apps
command -v brew   >/dev/null && record Brewfile brew bundle dump --file=-
command -v npm    >/dev/null && record npm-global.txt npm ls -g --depth=0
command -v uv     >/dev/null && record uv-tools.txt uv tool list
command -v mas    >/dev/null && record mas.txt mas list
command -v cursor >/dev/null && record cursor-extensions.txt cursor --list-extensions
command -v code   >/dev/null && record vscode-extensions.txt code --list-extensions

echo "inventory: $ok lists written to ~/.config/mac-backup/state/inventory${failed[0]+ (failed: ${failed[*]})}"
exit 0
