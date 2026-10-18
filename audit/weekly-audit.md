# Backup audit — prompt for the Claude scheduled task

Each Mac runs this with its own Claude Code. It is read-only: report findings and propose fixes,
but never change config, secrets, schedules or the repository without Pietro's approval.

Cadence: weekly for about three months after setup (October 2026), then monthly once the reports
are routine, then consider retiring it. The scripts and healthchecks.io already catch hard failures;
this audit adds trend reading and judgement.

Context: `~/.config/mac-backup/docs/backup-plan.md`. Helper: `~/.config/mac-backup/bin/restic.sh <args>`
runs restic against this Mac's repository. Logs: `~/Library/Logs/mac-backup/`. Last outputs:
`~/.config/mac-backup/state/*.last`.

## Checks

1. **Freshness.** `bin/restic.sh snapshots --json`: newest snapshot under 26 h old. Over the last
   7 days, roughly one snapshot per hour the Mac was awake. Laptops sleep, so judge the pattern, not a count.
2. **Backup runs.** In `backup.log` for the last 7 days: any `FAIL`, skipped runs (lock, low battery),
   and the unreadable-file count on "ok with N unreadable files" lines. Also any content in `launchd-*.log`.
3. **Integrity.** `check.log`: a weekly check ran in the last 8 days and passed. In the first week of a
   month, the run used `--read-data-subset=5%`.
4. **Prune.** `prune.log`: ran in the last 8 days, ok.
5. **Full Disk Access.** `state/check.last` says `fda: ok`, and `backup.log` has no "Full Disk Access is missing".
6. **Critical paths.** `state/check.last` lists no "critical path MISSING".
7. **Size and cost.** Trend of the snapshot size in `check.log`. Repository stored size from
   `bin/restic.sh stats --mode raw-data`. Estimated cost at $6.95 per TB-month. Flag new bulk folders that
   look rebuildable and might deserve an exclude.
8. **Restore test.** `restore-test.log` has an ok entry in the last ~95 days.
9. **Scheduler.** `launchctl print gui/$(id -u)/com.pietro.mac-backup.backup` shows the job loaded.
10. **Config drift.** `git -C ~/.config/mac-backup fetch -q && git -C ~/.config/mac-backup status -sb`:
    no local changes, not behind `origin/main`.

## Report

One short message: a status line (OK, ATTENTION or BROKEN), then findings, then proposed actions.
