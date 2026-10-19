# Laptop backup plan — restic → Backblaze B2, operated by Claude

Status: v10, 2026-10-19 (phases C and D done: both Macs back up hourly; open: M2 iCloud folders, see audit item 13). Lives in `pietrog30/mac-backup-config` at `docs/backup-plan.md`. Owner: Pietro. Operator: Claude Code (one account per laptop).
This file is the single source of truth for the project. Tick boxes as steps complete; both laptops follow it.

## Operator notes (for Claude, on every laptop)

- **No next-step cards.** In the Claude desktop app, do not end a turn with a question card or buttons. Write the full answer, including any question or next step, as normal text in the final message. Reason (Pietro, 2026-10-18): the cards hide the output text.
- Never ask for or echo secrets. Pietro fills `secrets.env` himself; Claude only checks it is mode 600 and has no placeholders.
- Do not change config, schedules or the repository without Pietro's approval, except for steps in this plan he has asked to run. One standing exception: the audit task runs `git pull --ff-only` on a clean tree.

## 0. Decisions (settled)

| Topic | Decision |
|---|---|
| Tool | restic (open source, fully scriptable, repo = plain files). Arq rejected: GUI-only config. Kopia rejected: weaker macOS metadata, GUI is its only edge. |
| Storage | Backblaze B2, region **EU Central** (Pietro lives in Italy; faster restores, EU data residency; the Toronto-time laptop is physically in Italy too), one private bucket with lifecycle "hide, keep prior versions 30 days" (soft delete: a laptop key cannot irrecoverably wipe its own backup), **two repositories** (one per laptop, prefix `m4/` and `m2/`). Separate repos = no lock contention, per-laptop keys. Accessed through B2's S3-compatible endpoint with restic's `s3:` backend (more robust than the native `b2:` backend). Soft delete protects against mistakes, buggy prunes and naive malware; a stolen laptop key can still delete specific versions, so true immutability would need Object Lock (not used). S3 rejected on price and because a company AWS account is the wrong home for personal laptop backups. |
| Scope | Whole home directory, default-include, with an exclude list (section 7). Mail and Photos libraries out of scope. |
| Schedule | Backup hourly (revisit to every 4 h after the first week if the logs show it is intrusive). `forget --prune` weekly. `check` weekly, with 5% data read monthly. Test restore quarterly. |
| Retention | keep 24 hourly, 14 daily, 8 weekly, 12 monthly. |
| Secrets | Source of truth: Apple Passwords app (iCloud-synced to both Macs), one entry per laptop with repo URL, restic password, B2 keyID/key, healthchecks URL. Machine copy: `~/.config/mac-backup/secrets.env`, mode 600, per laptop (readable by launchd, no keychain ACL prompts; FileVault encrypts at rest). Login keychain not used. Never in the config repo. |
| Config | Private GitHub repo `pietrog30/mac-backup-config`, cloned to `~/.config/mac-backup` on each Mac. Text only, no data, no secrets. |
| Full Disk Access | Granted to one tiny compiled binary, `bin/mac-backup-runner`, which launchd starts and which execs the job scripts. macOS attributes FDA to the launchd-started process and its children inherit it, so restic upgrades never lose access. Granting FDA to the restic binary would not work under launchd, because bash, not restic, would be the responsible process. |
| Monitoring | healthchecks.io, two checks per laptop: `backup-<host>` (period 24h, grace 12h) and `check-<host>` (period 8d). Scripts also do size sanity checks. Plus a weekly Claude scheduled task on **both** laptops (each audits its own repo and local health). Cadence plan: weekly for the first ~3 months → monthly once the reports are boring → consider removing once scripts + healthchecks have proven themselves. |
| Old HGST disk, Time Machine | Deferred to the very last step (phase Z). Not part of the core goal. |

Expected cost: the M4 measured at ~8.6GB stored (section 1); both laptops plus a year of history likely 20–40GB → **well under $1/month** on B2. Restores free (3× stored egress allowance).

## 1. Facts gathered (this laptop, M4)

- Model: MacBook Air M4, macOS 15.6.1, Homebrew 7.0.8. restic/rclone/b2 not installed.
- Hostnames: `hostname` = `abhijeets-macbook-air-7.home`, LocalHostName = `Abhijeets-MacBook-Air-7`, ComputerName = "Abhijeet's MacBook Air (5)". Misleading; restic will be run with `--host m4-air` instead of relying on hostname.
- No iCloud Drive on this Mac.
- Home = 190GB. Rebuildable bulk: Docker container 68GB, Cursor `globalStorage` 34GB (state.vscdb 16GB + .backup 12GB + agent-worker 6GB), Claude Desktop `vm_bundles` 10GB + caches 1.5GB, `~/Library/Caches` 6.6GB, Chrome 2.8GB. Plus `~/.cache` 41GB (uv package cache 38GB), `~/.npm` 0.8GB, Cursor extensions 1.5GB — all excluded.
- **Measured payload (dry-run 2026-10-18, restic 0.19.1):** 269k files, 25.3GB read, 21.4GB unique, **8.6GB stored** after compression (transcripts compress very well). The scan took 59 s, so hourly runs are cheap. The dry-run hit 797 read errors in macOS-protected `~/Library` folders because it ran without Full Disk Access; the first real run under the runner shows how many remain, and `MB_MAX_READ_ERRORS` (25) gets tuned then.
- Critical small set (must be covered, verify in first snapshot): `~/.claude` (settings.json, scheduled-tasks/, projects/ transcripts 3.9GB, skills/, plugins/, hooks/, plans/), `~/.aws`, `~/.ssh`, `~/.config/ghostty`, `~/.zshrc`, `~/.gitconfig`, `~/Library/Application Support/Claude` minus caches, `~/github`.
- External disk `BACKUP PIET`: 1TB HGST 2015, HFS+ case-sensitive, 858GB used. Contents: `Backups.backupdb/Pietro's MacBook Pro/` (19 snapshots 2017-06 → 2020-07 + one 2021-05 inProgress) and `FILES/` ≈ 33GB (FOTO, backup Foto, backup itunes iphone, Musica Iphone, video, video silvio, websites, WEP). Terminal cannot read it without Full Disk Access; Finder can.

### Performance findings (first day, M4)

- Upload capacity is 97 Mbit/s with many connections but only **3–9 Mbit/s per connection** (measured to Cloudflare and B2). restic therefore uses 16 parallel S3 connections (`MB_S3_CONNECTIONS`); the first backup averaged ~38 Mbit/s.
- Hourly runs read everything in ~30 s, then upload ~200MiB one pack at a time at single-connection speed, so they take **8–14 minutes**, in the background with ~0% CPU. Harmless. The volume is mostly real activity: Claude transcripts appended by running sessions, plus Chrome and app databases.
- Tested and ruled out as causes: low-priority I/O and `Nice` (kept), 64MiB packs (reverted to restic's default 16MiB), HTTP/2 multiplexing.
- Possible future improvement, not needed: try Ethernet to see if per-connection upload speed rises.

## 2. Phase A — Accounts and secrets (Pietro, ~20 min, once)

- [x] A1. Backblaze account, created with region **EU Central** (the region is picked at sign-up and applies to every bucket; it cannot be changed later). Enable 2FA. Create bucket `pietro-mac-backups` (names are global; if taken, pick a variant and record it here: `________`) (private; server-side encryption SSE-B2 is automatic and cannot be turned off; harmless, restic encrypts client-side too; lifecycle rule: **keep prior versions for 30 days** (not "keep only the last version"); Object Lock off). S3 endpoint: **`s3.eu-central-003.backblazeb2.com`** (recorded 2026-10-18).
- [x] A2. Create two B2 application keys, each restricted to the bucket and a name prefix:
  - `restic-m4` → prefix `m4/`
  - `restic-m2` → prefix `m2/`
  Capabilities: listBuckets, listFiles, readFiles, writeFiles, deleteFiles. Record keyID + applicationKey in the Passwords app (A3).
- [x] A3. Generate two restic passwords (`openssl rand -base64 32`), one per laptop. Apple Passwords entries: `restic m4-air`, `restic m2-air` (use the Notes field), each holding: repo URL, password, B2 keyID, B2 key, healthchecks URLs.
- [x] A4. healthchecks.io account → four checks: `backup-m4-air`, `backup-m2-air` (period 1 day, grace 12 h) and `check-m4-air`, `check-m2-air` (period 8 days, grace 1 day), email alert. Record ping URLs in the Passwords entries.
- [x] A5. GitHub → private repo `mac-backup-config` under Pietro's **personal** account `pietrog30`, empty: https://github.com/pietrog30/mac-backup-config (clone as `git@github-mac-backup:pietrog30/mac-backup-config.git` via the `~/.ssh/config` alias). Access is by a per-laptop **deploy key** with write access (repo Settings → Deploy keys), not by any account login: `~/.ssh/mac-backup-config` (M4 key created 2026-10-18). The `gh` CLI on the M4 is logged in as `pietro-devagent` (work/agent token) and is not used for this repo.

## 3. Phase B — Build the config repo (Claude, this laptop)

Layout (built 2026-10-18):

```
mac-backup-config/
  README.md              overview, bootstrap, restore
  install.sh             idempotent: brew install restic, build + sign the runner, create secrets.env, write LaunchAgents; --load / --unload
  src/runner.c           mac-backup-runner source: accepts only backup|prune|check|restore-test, execs bin/<job>.sh
  bin/env.sh             sourced by jobs: loads secrets.env + hosts/<host>.env, PATH, logging, lock, healthchecks ping, FDA probe, battery check
  bin/backup.sh          hourly backup of $HOME
  bin/prune.sh           weekly forget --prune (24h/14d/8w/12m)
  bin/check.sh           weekly: FDA probe, restic check (5% read in week 1 of a month), critical paths, size trend
  bin/restore-test.sh    quarterly: restore a random small critical folder with --verify
  bin/restic.sh          manual helper: restic with this Mac's secrets loaded
  bin/inventory.sh       writes installed-software lists to state/inventory/ (weekly via check.sh; no secrets needed)
  excludes.txt           shared exclude list — the source of truth (section 7 only summarizes)
  critical-paths.txt     paths that must be in every snapshot when they exist locally
  hosts/<host>.env       RESTIC_REPOSITORY + AWS_DEFAULT_REGION per Mac; optional hosts/<host>.excludes
  secrets.env.example    template for the gitignored secrets.env
  audit/weekly-audit.md  prompt for the Claude scheduled task
  docs/backup-plan.md    this file
```

Implementation rules:
- Scripts are `bash` 3.2-compatible (macOS `/bin/bash`), `set -euo pipefail`, log to `~/Library/Logs/mac-backup/<job>.log` (rotated at 5 MB), exit non-zero on any failure.
- Secrets come only from `secrets.env` (mode 600, gitignored): `BACKUP_HOST`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (B2 keyID/key), `HC_BACKUP_URL`, `HC_CHECK_URL`. Scripts refuse to run if it is missing, not mode 600, or still has placeholders.
- `backup.sh`: takes a lock (mkdir-based; macOS has no `flock`), skips if another job holds it or if on battery below 20%, pings `/start`, fails fast if the FDA probe fails, runs `restic unlock` (stale locks only), then `restic backup ~ --one-file-system --no-scan --exclude-caches --exclude-if-present .nobackup` with `RESTIC_PACK_SIZE=64`. Exit 3 (some files unreadable) counts as success up to 25 unreadable files, otherwise fail. Output tail goes to healthchecks.
- `prune.sh`, `check.sh`, `restore-test.sh` wait up to 1 h for the lock. Failures ping `HC_CHECK_URL/fail`; `check.sh` pings `HC_CHECK_URL` on success.
- FDA probe: reading `~/Library/Application Support/com.apple.TCC/TCC.db`, which only succeeds with Full Disk Access.
- LaunchAgents `com.pietro.mac-backup.<job>` are generated by `install.sh`: `StartCalendarInterval` (backup :17 hourly, prune Sun 12:41, check Wed 12:41, restore-test 2 Jan/Apr/Jul/Oct 12:51), `Nice 10`, `LowPriorityIO`. Missed runs fire once on wake.
- Nothing machine-specific outside `hosts/`.

- [x] B1. Write files above, move this plan into `docs/`, commit, push.
- [x] B2. Review exclude list against this Mac with a dry-run (results in section 1).

## 4. Phase C — Install on this laptop (M4)

- [x] C1. Config repo already cloned to `~/.config/mac-backup` (done in B). Run `install.sh`.
- [x] C2. **Pietro:** fill `~/.config/mac-backup/secrets.env` (created by install.sh, mode 600) from the Passwords app entry `restic m4-air`, with `BACKUP_HOST='m4-air'`. Claude never sees the values.
- [x] C3. **Pietro:** System Settings → Privacy & Security → Full Disk Access → + → `~/.config/mac-backup/bin/mac-backup-runner` (press Cmd+Shift+. in the file picker to show the hidden `.config` folder). Not the restic binary.
- [x] C4. `bin/restic.sh init` (repository `s3:https://s3.eu-central-003.backblazeb2.com/pietro-mac-backups/m4`). Done 2026-10-18: repository ID `7ca1f101db`; the prefix-restricted key works over the S3 endpoint, no fallback needed. If the S3 API rejects the prefix-restricted key, fall back to restic's native `b2:` backend (same key, `B2_ACCOUNT_ID`/`B2_ACCOUNT_KEY`) and record it in section 0.
- [x] C5. `install.sh --load`, then start the first backup with `launchctl kickstart gui/$(id -u)/com.pietro.mac-backup.backup` so it runs under the runner's FDA (a run started from Claude or a terminal gets that app's permissions instead). Keep the Mac awake and on power: `caffeinate -s -w <pid>` or just leave it plugged in with the lid open. ~8.6GB to upload: roughly 15 min at 100 Mbit/s up, 1 h at 20 Mbit/s.
- [x] C6. Verify: `restic snapshots`, `restic ls latest ~/.claude/settings.json ~/.aws ~/.ssh/config` present; `restic stats` roughly matches estimate; healthchecks shows a ping.
- [x] C7. Confirm the next hourly run completes on its own (`backup.log` + healthchecks).
- [x] C8. Test restore: `launchctl kickstart gui/$(id -u)/com.pietro.mac-backup.restore-test`, plus a manual `bin/restic.sh restore latest --include ~/.claude/settings.json --target /tmp/r`. Also run the check job once the same way.
- [x] C9. Create the Claude scheduled task on this laptop: weekly, prompt exactly `Read ~/.config/mac-backup/audit/weekly-audit.md and follow it exactly.` The instructions live in git, never in the task. Done: task `backup-audit`, Thursdays 10:00. Its runs start in the default permission mode, so **Pietro clicks "Run now" once** and approves the commands, which are then remembered. The task's working folder must be `~/.config/mac-backup` on both Macs (set in the app's task editor; a folder Claude made for one session is deleted with that session).
- [x] C11. Test the alert path: send a `/fail` ping to `check-<host>` (body "TEST, ignore"), Pietro confirms the email arrives, then send a success ping to clear it. M4: done 2026-10-18; email arrived, alert cleared.
- [x] C10. Record restic version, repo ID, first snapshot ID and date here: restic 0.19.1; repository `7ca1f101db`; first snapshot `741f911a`, 2026-10-18 09:33, 276k files, 25.8GiB, **7.3GiB stored**, 4 unreadable files (now excluded). Restore test (`~/.claude/skills`, 456 files), weekly check and a manual restore of `settings.json` all passed the same day.

## 5. Phase D — Install on the other laptop (M2, its own Claude Code account)

Hand-off: the M2 gets this file from the config repo (`docs/backup-plan.md`); AirDrop only as a fallback. Its Claude reads sections 0, 3 (done), 4, 6, 7 and runs phase C with `hosts/m2-air.env`. Secrets come from the Passwords app (already synced), never from this file.

- [x] D1. GitHub access: the M2's Claude Code is believed to use Pietro's personal account directly, so it clones over HTTPS with no extra setup (verify with `gh auth status`). Fallback, if it is restricted like the M4: create an M2 deploy key (`ssh-keygen -t ed25519 -f ~/.ssh/mac-backup-config -N "" -C "m2-air mac-backup-config deploy key"`), Pietro adds it with write access, add the same `Host github-mac-backup` block to `~/.ssh/config`. Then clone the config repo, `install.sh`, `secrets.env` from the Passwords app, FDA grant. Progress 2026-10-18: `gh` is logged in as `pietrog30`, cloned over HTTPS (no deploy key needed), `install.sh` run (restic 0.19.1, runner built). `secrets.env` filled and FDA granted by Pietro the same day.
- [x] D2. `hosts/m2-air.env` exists. iCloud Drive decision (2026-10-18): **Desktop, Documents and iCloud Drive are excluded on the M2 for now** (`hosts/m2-air.excludes`; app data in iCloud, `~/Library/Mobile Documents`, is excluded on both Macs in `excludes.txt`). Measured: Desktop & Documents sync to iCloud with Optimize Mac Storage on; after the shared excludes they hold ~58 GB (plus `Documents/AX`, see D5, and `Documents/Courses`), of which only ~0.4 GB is downloaded, on a 228 GB disk with 16 GB free. Turning Optimize Mac Storage off is impossible (no space); backing them up as-is would force a download of everything. They rely on iCloud alone, which is sync, not backup; the weekly audit (item 13) reminds Pietro to reconsider and lists the options. `Documents/Zoom` (old meeting recordings, 41 GB) is deleted by Pietro, without a backup.
- [x] D3. `restic init` on `s3:https://s3.eu-central-003.backblazeb2.com/pietro-mac-backups/m2`, first backup, verify, launchd, restore test, scheduled task, alert-email test — same checks as C4–C11. Done 2026-10-18/19: repository `57f80aa05b` (prefix-restricted key works over S3); schedules loaded; first backup 19:11–21:31 under the runner, FDA ok. It read 154 GiB because 120 GiB of OneDrive placeholders in `~/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite/` read as zeros (nothing real uploaded); that folder is now excluded on both Macs. Second snapshot 24.6 GiB. `restic check` ok, critical paths ok, manual restore of `settings.json` identical. Restore test: data restored and verified, but `restore-test.sh` exited 1 without logging when restored files differ from live ones (`diff | wc -l` under `pipefail`); fixed 2026-10-19, rerun ok. `check.sh` size line no longer prints the raw byte count. Scheduled task `backup-audit`, Thursdays 10:00, saved in Auto mode, working folder `~/.config/mac-backup`. Alert path: the two failed checks at 21:34/21:36 sent real `/fail` pings to `check-m2-air`; Pietro confirmed the emails, and the next ok check cleared them.
- [x] D4. Record M2 facts (model, home size, payload, snapshot ID) here: MacBook Air M2 (Mac14,2), macOS 15.7.9, hostname `pietros-macbook-air-6.home`, home 56 GB on disk, disk 228 GB with 16 GB free. restic 0.19.1; repository `57f80aa05b`; first snapshot `2494f055` 2026-10-18 19:11 (includes the OneDrive zeros); first clean snapshot `70791bfa` 21:36: 263,878 files, 24.6 GiB; repository **20.5 GiB stored**; 2 unreadable files (Google updater stats, an iZotope installer's saved state). Hourly incremental runs take ~20 min (same single-connection upload limit as the M4).
- [x] D5. **Move `Documents/AX` to the M4** (29.4 GB, iCloud-only on the M2: ~26 GB of videos in `salesprocess`, plus `dev`, `Leads`, `L1A`, `SWS Contract`). Run on the M4 by its Claude, with Pietro for the settings steps:
  1. `git pull` on the M4 and confirm `excludes.txt` has `$HOME/Library/Mobile Documents`. Without it, the M4's hourly backup would read the iCloud placeholders that appear in step 3 and download all of iCloud.
  2. Check free space on the M4 (`df -h ~`): AX needs ~30 GB plus headroom.
  3. **Pietro:** System Settings → Apple Account → iCloud → iCloud Drive → on. Leave **"Desktop & Documents Folders" off**, otherwise the M4's own Desktop and Documents move into iCloud.
  4. In Finder, copy `iCloud Drive/Documents/AX` to `~/Desktop/AX` (a copy, not a move; Finder downloads it from iCloud). Wait until it has fully downloaded, then compare file counts and total size with the iCloud folder.
  5. Let the next hourly backup run, then `bin/restic.sh ls latest ~/Desktop/AX` and restore one file to `/tmp` to confirm it is in B2.
  6. Only then, **Pietro** deletes `Documents/AX` from iCloud (Finder; it stays in iCloud's Recently Deleted for 30 days). Optionally turn iCloud Drive off on the M4 again; the local `~/Desktop/AX` is unaffected. If macOS offers to keep a copy of iCloud Drive, decline: the copy would download everything into the home folder, outside the excludes.
  7. Record the date and the first snapshot that contains it here: 2026-10-18, M4 snapshot `a3e80861` (details below).

  Progress on the M4 (2026-10-18): steps 1–5 done. Finder's copy and "Download Now" stalled for over 30 minutes (iCloud had just been turned on and was still listing thousands of small files), so the copy was done from Terminal instead: each file was read to force the download, 8 at a time, then `rsync -a` copied everything to `~/Desktop/AX`. iCloud downloaded the large files at ~60 Mbit/s but tiny files at only ~8–40 a minute, so these were left out, all of them rebuildable: `venv`/`.venv`/`node_modules`/`__pycache__`, and the `.git` folders of `dev/ChatGPT/Ross AI` and `dev/ChatGPT/customer-manager`. Both repos are on GitHub (`asteroidx-me/Ross-AI`, `asteroidx-me/customer-manager`) and cloned in `~/github`. All 7 Ross AI branches were found in the clone; only an old `git stash` existed nowhere else, and it is given up. Result: 4,730 files, 28.25 GB, names and sizes identical to iCloud. First snapshot containing it: `a3e80861` (16:17 run, 1 h 56 min, +29.2 GiB, 24.3 GiB stored). The snapshot holds every AX file except 29 pytest/ruff cache files (left out by `--exclude-caches`). A test restore of 3 files (585 MiB, including a video and the SWS employment agreement) was byte-identical. Step 6: Pietro deleted `Documents/AX` from iCloud by 2026-10-19 (gone on the M2).

## 6. Phase E — Operations runbook

Claude scheduled task on both laptops, each auditing its own repo. The task holds only a one-line pointer to `audit/weekly-audit.md`; the audit pulls the repo first (fast-forward only, clean tree only), so editing the instructions once in git updates both Macs. **Cadence lives in each Mac's task settings, not in git: change it on both Macs together;** each report states its cadence so drift shows up. Cadence: weekly for ~3 months, then monthly, then possibly retire it — the scripts + healthchecks already catch hard failures; the task adds trend reading and judgement:
1. `restic snapshots --json`: newest snapshot < 26 h old; roughly one per awake hour over the last week (laptops sleep, so do not expect 24/day).
2. Tail `~/Library/Logs/mac-backup/backup.log` for errors; read healthchecks status.
3. `restic check` output from the last weekly run is clean; monthly read-data run happened.
4. FDA probe passed; restic version unchanged or deliberately upgraded.
5. `restic stats latest` size trend; flag a jump > 20% (new bulk folder needs an exclude?) or a drop > 20% (something stopped being backed up?).
6. Report in one message; propose fixes, do not change config without approval.

Quarterly (launchd + reviewed by the audit): `restore-test.sh` restores one random folder and diffs it.

Common tasks:
- Manual restic: `~/.config/mac-backup/bin/restic.sh <args>` loads this Mac's secrets.
- Restore one file: `bin/restic.sh restore latest --include <path> --target /tmp/restore`.
- Restore from a date: `restic snapshots` → pick ID → `restic restore <ID> --include <path> --target …`.
- Bare-metal (new Mac): install Homebrew + restic, fetch the laptop's entry from the Passwords app, `export RESTIC_REPOSITORY/RESTIC_PASSWORD/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_DEFAULT_REGION`, `restic restore latest --target ~` (or `--include` for the critical set only), then re-run phase C so the new machine backs up.
- Rotate B2 key: create new key in Backblaze, replace in `secrets.env` + Passwords app, delete old key.
- Test alerts: `bash -c 'source ~/.config/mac-backup/bin/env.sh; echo "TEST, ignore" | curl -fsS --data-binary @- "$HC_CHECK_URL/fail"'`, confirm the email, then the same with no `/fail` suffix to clear it.
- Add a device (e.g. Mac mini, ~30 min): new B2 key with prefix `mini/`, new password, Passwords entry, `hosts/mac-mini.env`, clone config repo, `install.sh`, secrets.env, FDA grant, `restic init`, first backup, launchd, Claude task. Same bucket, no new accounts.
- Move storage: `rclone sync <b2 remote>:… <new>` then change `REPO` in the host env file. No re-upload from laptops.
- Change tool: new tool starts from today; keep the restic repos read-only for ≥ 12 months (≈ $1/month). History can be replayed into restic with `backup --time` if ever needed.
- Upgrade restic: plain `brew upgrade restic` is safe; FDA belongs to the runner, not restic. Rebuilding the runner (only if `src/runner.c` changes) changes its signature: re-grant FDA, then kickstart the check job.
- Reinstall software on a new Mac: `brew bundle --file ~/.config/mac-backup/state/inventory/Brewfile` after restoring the home folder; the other lists in `state/inventory/` (apps, npm globals, uv tools, editor extensions) are a checklist.
- Add a folder to excludes: edit `excludes.txt`, commit, push, `git pull` on the other laptop. Already-stored data ages out via retention.

## 7. Exclude list (draft, refine in B2)

The list itself is `excludes.txt` in the repo (source of truth). Categories: macOS caches/logs/Trash; developer caches and package stores (`~/.cache` incl. uv's 38GB cache, `~/.npm`, `~/.local/share/uv`, `~/.local/share/claude`, `node_modules`, `.venv`, `__pycache__`, `.next`, `.turbo`, Rust `target/`); Docker's container; Cursor caches, extensions and its chat-state database; Claude Desktop VM bundles, bundled CLI versions and browser caches; Claude Code caches and debug output; Chrome caches; `~/Library/CloudStorage` placeholders; Mail and Photos (out of scope). Plus `--exclude-caches` and `--exclude-if-present .nobackup`; drop an empty `.nobackup` file into any folder to exclude it.

Per-host: `hosts/m2-air.excludes` excludes `~/Desktop` and `~/Documents` (D2). `~/Library/Mobile Documents` (iCloud Drive and app data in iCloud) is in the shared `excludes.txt`, so turning on iCloud Drive on any Mac never triggers a mass download.

Notes:
- **M2 / iCloud Drive:** the M2 syncs Desktop and Documents to iCloud with "Optimize Mac Storage" on, so they are almost entirely dataless placeholders and restic would force a download of everything. Decided in D2: excluded for now, relying on iCloud; reconsider via the weekly audit (item 13).
- Docker exclude drops anything stored in Docker volumes. Fine unless a local database there matters.
- `~/Library/Logs` exclude also drops the backup logs themselves; acceptable.

Exclude decisions:
- `Cursor/User/globalStorage/state.vscdb` (16GB, Cursor chat history, changes constantly): **excluded** (decided 2026-10-18). Flip if Cursor history ever matters.
- `~/github` (7.3GB): **include** (unpushed branches). node_modules already excluded.
- `~/Downloads` (2.7GB): include.
- `~/Library/Application Support/Claude/claude-code` and `claude-code-vm`: **excluded** (bundled CLI binaries, re-downloaded). `claude-code-sessions`, `local-agent-mode-sessions`, configs: included.

## 8. Decision log

- 2026-10-19 (v10): phase D done. OneDrive's real sync folder excluded on both Macs (its placeholders read as zeros). Rebuildable bulk excluded (Chrome extensions, Google updater, Drive cache, pnpm store, DiffusionBee models). Audit task folder = `~/.config/mac-backup`. `.DS_Store` untracked so Finder cannot dirty the tree the audit pulls into.

- 2026-10-18 (v9, phase D started on the M2): M2's Desktop, Documents and iCloud Drive excluded for now (iCloud-only placeholders, disk nearly full); the weekly audit reminds Pietro to reconsider, with the downsides and options. `~/Library/Mobile Documents` excluded on both Macs. `Documents/AX` moves to the M4's Desktop (D5). `Documents/Zoom` deleted without a backup. A one-time archive snapshot of `Documents/Courses` was discussed and deferred with the rest.

- 2026-10-18: region EU Central; Apple Passwords app + 600 env file; hourly; Claude task on both laptops (weekly → monthly → retire); Cursor state excluded; old disk / Time Machine deferred to phase Z.
- 2026-10-18 (v8): phase C done on the M4. Pack size back to restic's default; excluded 4 always-unreadable Apple folders plus churning macOS telemetry and Chrome safe-browsing/favicons. Hourly runs take 8–14 min because of single-connection upload speed (see section 1).
- 2026-10-18 (v7, first backup): restic uploads with 16 parallel S3 connections (`MB_S3_CONNECTIONS`); with restic's default of 5, B2 reached only 10–14 Mbit/s on a 97 Mbit/s line, with 16 it reached 53 Mbit/s. Low-priority disk I/O was tested and was not the bottleneck.
- 2026-10-18 (v6): installed software is not backed up (reinstallable); a weekly inventory (Brewfile, apps, global packages) is written into the home folder instead. Scheduled task = one-line pointer to the audit file in git; the audit pulls first; cadence changed on both Macs together.
- 2026-10-18 (v5, phase B): FDA via a compiled runner instead of the restic binary (no brew pin needed); mkdir lock instead of flock; `~/.cache` and other dev caches excluded after finding 41GB there; 25-unreadable-file tolerance; plan moved into the repo.
- 2026-10-18 (v4): bucket soft-delete 30 days; S3-compatible endpoint; cloud-placeholder folders excluded; plan lives in the config repo; `critical-paths.txt` checked weekly; flock/unlock/battery guard/pack-size 64 in `backup.sh`; restic upgrade procedure; Docker-volume and logs caveats noted.

## Phase Z — Last, deferred: old HGST disk and Time Machine

Do nothing here until everything above is running on both laptops. Kept for reference.

- [ ] Z1. Grant Full Disk Access to the Claude desktop app (System Settings → Privacy & Security → Full Disk Access) so Claude can read `/Volumes/BACKUP PIET`. Alternative: do the copy in Finder.
- [ ] Z2. Copy `/Volumes/BACKUP PIET/FILES` → `~/Archive/old-macbook-pro/FILES` (33GB, 5400rpm disk → ~30–60 min). Use `rsync -avE --progress`, then `rsync -avEc --dry-run` to verify checksums; expect zero differences.
- [ ] Z3. Browse `Backups.backupdb/Pietro's MacBook Pro/Latest/Users/<user>/` for anything else worth keeping (Documents, Desktop, dotfiles). Copy to `~/Archive/old-macbook-pro/latest-snapshot/`. Decide and record here what was taken.
- [ ] Z4. Decide whether `~/Archive` joins the cloud backup (adds ~33GB ≈ $0.25/month).
- [ ] Z5. Only then decide about Time Machine (below).

Time Machine (optional second layer): Only after Z2 is verified. Either erase `BACKUP PIET` to APFS (loses the 2017–2021 snapshots of the old Mac) and use it as a stopgap, or buy a 1–2TB SSD. Time Machine → add disk; plug into each laptop weekly. Do not rely on it; it is convenience, not protection.

