# Time Machine Optimizer

Time Machine backs up every hour. When the backup disk is a NAS, every hourly run keeps its hard drives busy for several minutes, even when little has changed. This project switches a Mac to one backup per night, catches up after nights the Mac was off, and keeps caches and reinstallable software out of the backup.

It was built for a Mac mini backing up to a Synology NAS over SMB, but works with any Time Machine destination. Tested on macOS 27.

## Files

| File | What it does |
|---|---|
| `tm-nightly.sh` | Checks whether a backup is due and starts it |
| `local.tm-nightly.plist` | launchd job that runs `tm-nightly.sh` every hour and at login |
| `install.sh` | Installs or removes the job for the current user |
| `exclusions.txt` | Folders to leave out of backups; edit it for your Mac |
| `exclude.sh` | Applies `exclusions.txt` |
| `tests/` | Tests for `tm-nightly.sh` and `exclude.sh` |

## How the job decides

launchd runs `tm-nightly.sh` every hour on the hour and when you log in. Each time, the script:

- **Between 01:00 and 06:00:** starts a backup, unless one finished in the last 6 hours.
- **At other times:** starts a backup only if the last one is more than 26 hours old, meaning a night was missed. After a restart, it first waits until the Mac has been on for 15 minutes.
- **If no backup has finished for 3 days:** shows a notification, at most once a day.
- **Before each backup, if you use Homebrew:** saves your package list to `~/.config/Brewfile` (see [Homebrew](#homebrew)). If that fails, you get a notification and the backup runs anyway.

It does nothing while a backup is already running.

## Homebrew

If you use Homebrew, your packages are meant to be reinstalled from the Brewfile, not restored from the backup. The job saves the Brewfile before each backup, so the backup always has a current list. To reinstall everything on a new or restored Mac:

```bash
brew bundle --file ~/.config/Brewfile
```

That's why `exclusions.txt` leaves out `/opt/homebrew`. If you exclude it without using this job, keep a Brewfile up to date some other way.

Without Homebrew, everything else works the same: the job skips the Brewfile, and `exclude.sh` skips `/opt/homebrew` because the folder doesn't exist.

## Install

You need a Time Machine backup disk that is already set up.

1. In System Settings → General → Time Machine → Options, set **Back up frequency** to **Manually**. Otherwise Time Machine keeps its hourly backups going next to this job.
2. Clone the repository and run the installer:
   ```bash
   git clone git@github.com:DavidSutta/time-machine-optimizer.git
   cd time-machine-optimizer
   ./install.sh
   ```
3. Run one backup through the job to check that it works:
   ```bash
   ~/Library/Scripts/tm-nightly.sh --now
   ```

macOS shows a "Background Items Added" notice. Keep the item turned on in System Settings → General → Login Items & Extensions, or the job won't run.

To change the job later, edit `tm-nightly.sh` here and run `./install.sh` again.

## Settings

The settings are at the top of `tm-nightly.sh`:

| Setting | Default | Meaning |
|---|---|---|
| `NIGHT_START`, `NIGHT_END` | `1`, `6` | Night window: from 01:00 up to 06:00, local time. It can cross midnight, for example `22` and `6` |
| `NIGHT_MIN_AGE_H` | `6` | In the window, skip if a backup finished within this many hours |
| `CATCHUP_AGE_H` | `26` | Outside the window, back up once the last backup is this many hours old |
| `LOGIN_DELAY_S` | `900` | After a restart, wait this many seconds before a catch-up backup |
| `WARN_AGE_H` | `72` | Notify when the last backup is this many hours old |
| `BREWFILE` | `~/.config/Brewfile` | Where to save the Homebrew package list; `""` turns it off |

To see what the job would do right now, without changing anything:

```bash
~/Library/Scripts/tm-nightly.sh --dry-run
```

## Exclusions

`exclusions.txt` lists folders that are caches or can be downloaded again, each with a comment saying why it's safe to leave out. Delete the lines you don't want and uncomment the optional ones that fit your Mac. Folders your Mac doesn't have are skipped.

```bash
./exclude.sh            # show each folder's status; changes nothing
./exclude.sh --apply    # exclude the folders (asks for your password)
./exclude.sh --remove   # put them back into backups
```

Backups made before a folder was excluded still contain it.

## Check that it works

```bash
tail -20 ~/Library/Logs/tm-nightly.log
```

The log has a line for every backup the job starts and how it ended. Hours when no backup was due leave no line. `tmutil status` shows whether a backup is running right now.

## Tests

```bash
./tests/run.sh          # run all tests
./tests/run.sh window   # run the tests with "window" in their name
```

The tests run the real scripts with fake versions of `tmutil`, `defaults`, `date` and the other system commands they use. They don't start backups, change Time Machine settings or show notifications, and they need nothing beyond macOS.

## Uninstall

```bash
./install.sh --uninstall
```

Then set Time Machine's **Back up frequency** back to **Automatically every hour**, or whichever schedule you want.

## Limits

- The job runs only while you're logged in. A locked screen is fine.
- If the Mac is off or asleep at night, the backup happens during the day instead, once the last one is 26 hours old.
- With FileVault on, scheduling the Mac to switch on at night doesn't help: it stops at the login screen, and nothing can back up until you log in.
- Only the first Time Machine destination is checked when deciding whether a backup is due.
