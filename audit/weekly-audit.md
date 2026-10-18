# Backup audit — prompt for the Claude scheduled task

Each Mac runs this with its own Claude Code. It is read-only: report findings and propose fixes,
but never change config, secrets, schedules or the repository without Pietro's approval.

Cadence: weekly for about three months after setup (October 2026), then monthly once the reports
are routine, then consider retiring it. The scripts and healthchecks.io already catch hard failures;
this audit adds trend reading and judgement.

The scheduled task itself holds only a one-line pointer to this file, so both Macs always run the
same instructions from git:

> Read `~/.config/mac-backup/audit/weekly-audit.md` and follow it exactly.

Context: `~/.config/mac-backup/docs/backup-plan.md`. Helper: `~/.config/mac-backup/bin/restic.sh <args>`
runs restic against this Mac's repository. Logs: `~/Library/Logs/mac-backup/`. Last outputs:
`~/.config/mac-backup/state/*.last`.

## Checks

0. **Sync first.** If `git -C ~/.config/mac-backup status --porcelain` is empty, run
   `git -C ~/.config/mac-backup pull --ff-only`; this is the one change the audit may make on its own.
   If the tree is dirty or the pull fails, do not fix it: report it. If the pull changed this file,
   re-read it before continuing.
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
10. **Config drift.** After step 0: no local changes, not behind `origin/main`.
11. **Inventory.** `~/.config/mac-backup/state/inventory/` files were updated in the last 8 days
    (written by the weekly check).
12. **Cadence.** State this Mac's audit cadence (weekly or monthly, from the scheduled task settings)
    in the report, so a mismatch between the two Macs is visible.
13. **Open decision: M2 iCloud folders (M2 only, `BACKUP_HOST=m2-air`).** Until Pietro has decided and
    this item is removed, end every M2 report with a short reminder. `~/Desktop`, `~/Documents` and
    iCloud Drive are excluded on the M2 (`hosts/m2-air.excludes`, decided 2026-10-18, plan D2) because
    "Optimize Mac Storage" keeps them almost entirely in iCloud and the disk is nearly full. Downsides of
    that setup, to restate in the reminder:
    - iCloud is sync, not backup: a deletion, overwrite or corruption (including by malware) reaches every
      device. Recently Deleted keeps files for 30 days; most files have no version history.
    - Losing access to the Apple account means losing these files.
    - This covers ~58 GB, including `Documents/UNI`, `Documents/producer` and `Documents/fotos e videos`, plus the
      `Documents/Courses` folder, whose one-time archive snapshot was also deferred.
    Options to put to Pietro: (a) back them up hourly with restic's `--ignore-ctime` after a first pass
    in ~8 GB batches (tested 2026-10-18: downloading or evicting a file changes only its ctime, so
    restic would then skip unchanged placeholders without downloading them); (b) mark small, important
    folders "Keep Downloaded" in Finder and back up only those; (c) move folders to the M4, as was done
    for `Documents/AX`; (d) one-time archive snapshots under a separate restic host name for folders that
    never change. Include the current size: free disk space (`df -h ~`) and the iCloud-only total
    (`find ~/Desktop ~/Documents -type f -flags +dataless -print0 | xargs -0 stat -f %z | awk '{s+=$1} END {print s/2^30 " GB"}'`).

## Report

One short message: a status line (OK, ATTENTION or BROKEN), then findings, then proposed actions.
