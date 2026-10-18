#!/bin/bash
# Run restic against this Mac's repository with its secrets loaded.
#   ~/.config/mac-backup/bin/restic.sh snapshots
#   ~/.config/mac-backup/bin/restic.sh restore latest --include ~/.zshrc --target /tmp/r
source "$HOME/.config/mac-backup/bin/env.sh"
exec restic "$@"
