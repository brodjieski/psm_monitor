# psm_monitor

Monitors FileVault (SecureToken) unlock-attempt and backoff state for local users (UID > 500) by parsing `psm list` and recording changes to a SQLite3 database. Runs hourly via LaunchDaemon.

## How it works

Each run records its timestamp in the `runs` table, then compares current `psm list` values against the last recorded state for each user. A new row is only written when something changes — so every row in `psm_records` represents a meaningful state transition. Two timestamps bracket when the change occurred:

- `window_start` — the previous run (earliest the change could have happened)
- `timestamp` — the current run (latest it could have happened)

`is_current = 1` marks the last known state per user.

## Files

| File | Description |
|------|-------------|
| `psm_monitor.zsh` | Collection script |
| `com.organization.psm-monitor.plist` | LaunchDaemon plist — runs hourly as root |
| `ea_psm_last_user.zsh` | Jamf Pro Extension Attribute |
| `build.sh` | Builds the installer `.pkg` using `pkgbuild` |
| `preinstall` | Unloads the daemon before installation |
| `postinstall` | Sets permissions and loads the daemon |

## Installation

### Customize the org identifier

Replace `com.organization` with your own reverse-DNS identifier in:

- `build.sh` — `IDENTIFIER`


### Build and install

```bash
./build.sh                                              # produces output/psm_monitor-1.0.pkg
./build.sh 1.0                                          # specify a version
sudo installer -pkg output/psm_monitor-1.0.pkg -target /
```

### Removal

```bash
sudo launchctl unload /Library/LaunchDaemons/com.organization.psm-monitor.plist
sudo rm /Library/LaunchDaemons/com.organization.psm-monitor.plist
sudo rm /usr/local/bin/psm_monitor.zsh
sudo rm -rf /var/db/psm_monitor   # optional — removes the database
```

## Database

**Location:** `/var/db/psm_monitor/psm_monitor.db`

```sql
CREATE TABLE runs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL
);

CREATE TABLE psm_records (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT    NOT NULL,
    window_start    TEXT,
    username        TEXT    NOT NULL,
    uuid            TEXT    NOT NULL,
    uid             INTEGER NOT NULL,
    failed_console  INTEGER NOT NULL DEFAULT 0,
    failed_other    INTEGER NOT NULL DEFAULT 0,
    backoff_console INTEGER NOT NULL DEFAULT 0,
    backoff_other   INTEGER NOT NULL DEFAULT 0,
    is_current      INTEGER NOT NULL DEFAULT 0
);
```

## Useful queries

```bash
sqlite3 /var/db/psm_monitor/psm_monitor.db
```

**Current state of all users**
```sql
SELECT timestamp, username, uid, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records WHERE is_current = 1 ORDER BY username;
```

**Users currently in a non-zero state**
```sql
SELECT timestamp, username, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records WHERE is_current = 1
  AND (failed_console > 0 OR failed_other > 0 OR backoff_console > 0 OR backoff_other > 0);
```

**Full history for a user**
```sql
SELECT window_start, timestamp, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records WHERE username = 'lisa' ORDER BY timestamp;
```

**All incidents with detection window**
```sql
SELECT window_start, timestamp AS detected_at, username, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records
WHERE failed_console > 0 OR failed_other > 0 OR backoff_console > 0 OR backoff_other > 0
ORDER BY timestamp DESC;
```

**Users whose values increased since the previous state**
```sql
SELECT curr.timestamp, curr.username,
       prev.failed_console AS prev_fc, curr.failed_console AS curr_fc,
       prev.backoff_console AS prev_bc, curr.backoff_console AS curr_bc
FROM psm_records curr
JOIN psm_records prev ON prev.username = curr.username
  AND prev.id = (SELECT id FROM psm_records WHERE username = curr.username AND id < curr.id ORDER BY id DESC LIMIT 1)
WHERE curr.is_current = 1
  AND (curr.failed_console > prev.failed_console OR curr.failed_other > prev.failed_other
    OR curr.backoff_console > prev.backoff_console OR curr.backoff_other > prev.backoff_other);
```

**Run history (last 48 runs, with gap detection)**
```sql
SELECT timestamp,
       lag(timestamp) OVER (ORDER BY id) AS previous_run,
       round((julianday(timestamp) - julianday(lag(timestamp) OVER (ORDER BY id))) * 24, 2) AS hours_since_prev
FROM runs ORDER BY id DESC LIMIT 48;
```

## Jamf Pro Extension Attribute

`ea_psm_last_user.zsh` reads the last logged-in user from `com.apple.loginwindow.plist`, resolves their UUID via `dscl`, and queries `psm list` live to return a single result string.

| Condition | Result |
|-----------|--------|
| All values zero | `Account OK` |
| Any value non-zero | `FUA[console,other] BO[console,other]` |
| User or UUID unresolvable | `ERROR: reason` |

In Jamf Pro create the EA with **Data type: String** and **Input type: Script**, then paste the contents of `ea_psm_last_user.zsh`.

**Suggested smart group criteria:**

| Criteria | Operator | Value |
|----------|----------|-------|
| PSM Last User Status | is not | Account OK |
| PSM Last User Status | like | FUA |
| PSM Last User Status | like | BO |
