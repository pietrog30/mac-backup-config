# mac-backup-config

Hourly, encrypted, versioned backups of each Mac's home directory to Backblaze B2 with restic.
Operated mostly by Claude Code. Full plan, decisions and runbook: [docs/backup-plan.md](docs/backup-plan.md).

## How it works

- `launchd` starts `bin/mac-backup-runner` (a tiny compiled binary, the only thing granted Full Disk Access),
  which runs one of `bin/backup.sh`, `prune.sh`, `check.sh`, `restore-test.sh`.
- Each Mac has its own repository: `pietro-mac-backups/<host>` in B2 (EU Central), its own B2 key and password.
- Secrets live in `~/.config/mac-backup/secrets.env` (mode 600, never committed) and in the Passwords app.
- healthchecks.io emails when a backup or weekly check is missed or fails.

| Job | When | What |
|---|---|---|
| backup | hourly at :17 | `restic backup ~` with `excludes.txt` |
| prune | Sundays 12:41 | retention 24 hourly / 14 daily / 8 weekly / 12 monthly |
| check | Wednesdays 12:41 | integrity (5% data read in the first week of a month), critical paths, size trend, Full Disk Access |
| restore-test | quarterly | restore one random small critical folder and verify it |

Missed runs (Mac asleep) run once on wake.

## Bootstrap a Mac

```bash
git clone <repo> ~/.config/mac-backup
~/.config/mac-backup/install.sh            # installs restic, builds the runner, creates secrets.env
# fill secrets.env from the Passwords app, then grant Full Disk Access to bin/mac-backup-runner
~/.config/mac-backup/bin/restic.sh init    # first time only, per host
~/.config/mac-backup/install.sh --load     # enable the schedules
launchctl kickstart gui/$(id -u)/com.pietro.mac-backup.backup   # first backup, under the runner's FDA
```

## Restore

```bash
~/.config/mac-backup/bin/restic.sh snapshots
~/.config/mac-backup/bin/restic.sh restore latest --include ~/.aws --target /tmp/restore
```

On a new Mac without this repo: install restic, then export `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`,
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_DEFAULT_REGION` from the Passwords app entry and run
`restic restore latest --target /`.
