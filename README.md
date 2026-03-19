# psm_monitor

Monitors FileVault unlock-attempt and backoff state for local users by parsing the output of `psm list` (Protected Storage Manager) and recording changes to a SQLite3 database. Designed to run hourly as a LaunchDaemon.

## How it works

`psm list` exposes per-user KEK (Key Encryption Key) records that track how many times a user has failed to unlock the volume, and any backoff penalty that has been applied. This tool watches those values over time and records a new database row only when something changes — so the database stays small and every row is meaningful.

### Collection logic

Each run performs the following steps:

1. Records the current timestamp in the `runs` table and retrieves the previous run's timestamp as `window_start`
2. Runs `psm list` and parses each `-=-=-=-=-=-=-`-delimited block to extract the UUID and unlock/backoff counters
3. Enumerates local users with UID > 500 via `dscl`
4. Resolves each username to its GeneratedUID (which matches the UUID in `psm list`) via `dscl`
5. For each user, compares the current values against the last recorded row in the database
6. If the values are unchanged, nothing is written
7. If the values differ (or no prior row exists), a new row is inserted and the previous row's `is_current` flag is cleared

The result is a compact audit trail where each row represents a state transition rather than a periodic snapshot.

### The `is_current` flag

Every row has an `is_current` column. At most one row per user has `is_current = 1` at any time — the most recently recorded state for that user. Because rows are only inserted on change, the `timestamp` on an `is_current` row tells you when that state was first observed.

### Change windows

Each change row stores two timestamps that bracket when the change actually occurred:

| Column | Meaning |
|--------|---------|
| `window_start` | Timestamp of the previous run — the earliest the change could have happened |
| `timestamp` | Timestamp of the run that detected the change — the latest it could have happened |

So a change with `window_start = 2026-03-18T10:00:00Z` and `timestamp = 2026-03-18T11:00:00Z` occurred sometime in that one-hour window. The first row ever recorded for a user will have `window_start = NULL` since there is no prior run to reference.

---

## Files

| File | Description |
|------|-------------|
| `psm_monitor.zsh` | Collection script — parses `psm list`, compares to DB, records changes |
| `com.organization.psm-monitor.plist` | LaunchDaemon plist — runs the script hourly as root |
| `build.sh` | Builds the installer `.pkg` using `pkgbuild` |
| `pkg/root/` | Payload root — mirrors the target filesystem for `pkgbuild` |
| `pkg/scripts/preinstall` | Unloads the daemon before installation |
| `pkg/scripts/postinstall` | Sets permissions, creates the DB directory, loads the daemon |
| `output/` | Built `.pkg` files (not committed) |

---

## Installation

### Build the package

```bash
./build.sh           # produces output/psm_monitor-1.0.pkg
./build.sh 2.0       # specify a version
```

### Install

```bash
sudo installer -pkg output/psm_monitor-1.0.pkg -target /
```

Or distribute via MDM.

### Manual installation (without pkg)

```bash
sudo cp psm_monitor.zsh /usr/local/bin/psm_monitor.zsh
sudo chmod 755 /usr/local/bin/psm_monitor.zsh
sudo chown root:wheel /usr/local/bin/psm_monitor.zsh

sudo cp com.organization.psm-monitor.plist /Library/LaunchDaemons/
sudo chmod 644 /Library/LaunchDaemons/com.organization.psm-monitor.plist
sudo chown root:wheel /Library/LaunchDaemons/com.organization.psm-monitor.plist

sudo launchctl load /Library/LaunchDaemons/com.organization.psm-monitor.plist
```

### Customize the org identifier

Replace `com.organization` throughout with your own reverse-DNS identifier before building:

- `com.organization.psm-monitor.plist` — the `<key>Label</key>` value
- `build.sh` — the `IDENTIFIER` variable
- `pkg/scripts/preinstall` and `postinstall` — the `DAEMON_LABEL` variable

### Removal

```bash
sudo launchctl unload /Library/LaunchDaemons/com.organization.psm-monitor.plist
sudo rm /Library/LaunchDaemons/com.organization.psm-monitor.plist
sudo rm /usr/local/bin/psm_monitor.zsh
# Optionally remove the database
sudo rm -rf /var/db/psm_monitor
```

---

## Database

**Location:** `/var/db/psm_monitor/psm_monitor.db`

**Schema:**

```sql
-- One row per script execution. Used to derive window_start on change rows.
CREATE TABLE runs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL
);

-- One row per detected state change per user.
CREATE TABLE psm_records (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp       TEXT    NOT NULL,   -- UTC ISO 8601 — when this change was detected
    window_start    TEXT,               -- previous run's timestamp (NULL on first-ever run)
    username        TEXT    NOT NULL,
    uuid            TEXT    NOT NULL,   -- GeneratedUID / KEK UUID
    uid             INTEGER NOT NULL,
    failed_console  INTEGER NOT NULL DEFAULT 0,
    failed_other    INTEGER NOT NULL DEFAULT 0,
    backoff_console INTEGER NOT NULL DEFAULT 0,
    backoff_other   INTEGER NOT NULL DEFAULT 0,
    is_current      INTEGER NOT NULL DEFAULT 0  -- 1 = last known state for this user
);
```

`failed_console` and `failed_other` correspond to the `failed-unlock-attempts[console,other]` fields in `psm list`. `backoff_console` and `backoff_other` correspond to `backoff[console,other]`.

The change occurred within the window `window_start → timestamp`. On a system running the default hourly schedule, this window is at most one hour.

---

## Useful queries

Open the database:

```bash
sqlite3 /var/db/psm_monitor/psm_monitor.db
```

---

### Current state of all monitored users

```sql
SELECT timestamp, username, uid,
       failed_console, failed_other,
       backoff_console, backoff_other
FROM psm_records
WHERE is_current = 1
ORDER BY username;
```

---

### Users currently in a non-zero state

```sql
SELECT timestamp, username, uid,
       failed_console, failed_other,
       backoff_console, backoff_other
FROM psm_records
WHERE is_current = 1
  AND (failed_console > 0
    OR failed_other   > 0
    OR backoff_console > 0
    OR backoff_other   > 0)
ORDER BY username;
```

---

### Current state for a specific user

```sql
SELECT timestamp, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records
WHERE username = 'lisa' AND is_current = 1;
```

---

### Full history for a specific user

Each row is a state transition. `window_start` and `timestamp` bracket when the change occurred.

```sql
SELECT window_start, timestamp, failed_console, failed_other, backoff_console, backoff_other
FROM psm_records
WHERE username = 'lisa'
ORDER BY timestamp;
```

---

### All users who have ever had a non-zero value

```sql
SELECT DISTINCT username
FROM psm_records
WHERE failed_console > 0
   OR failed_other   > 0
   OR backoff_console > 0
   OR backoff_other   > 0
ORDER BY username;
```

---

### All recorded incidents (any non-zero state), most recent first

```sql
SELECT timestamp, username, uid,
       failed_console, failed_other,
       backoff_console, backoff_other
FROM psm_records
WHERE failed_console > 0
   OR failed_other   > 0
   OR backoff_console > 0
   OR backoff_other   > 0
ORDER BY timestamp DESC;
```

---

### Users whose values have increased since the previous recorded state

Useful for identifying an active, escalating failure sequence.

```sql
SELECT curr.timestamp, curr.username,
       prev.failed_console  AS prev_failed_console,  curr.failed_console  AS curr_failed_console,
       prev.failed_other    AS prev_failed_other,    curr.failed_other    AS curr_failed_other,
       prev.backoff_console AS prev_backoff_console, curr.backoff_console AS curr_backoff_console,
       prev.backoff_other   AS prev_backoff_other,   curr.backoff_other   AS curr_backoff_other
FROM psm_records curr
JOIN psm_records prev
  ON prev.username = curr.username
 AND prev.id = (
       SELECT id FROM psm_records
       WHERE username = curr.username AND id < curr.id
       ORDER BY id DESC LIMIT 1
     )
WHERE curr.is_current = 1
  AND (curr.failed_console  > prev.failed_console
    OR curr.failed_other    > prev.failed_other
    OR curr.backoff_console > prev.backoff_console
    OR curr.backoff_other   > prev.backoff_other);
```

---

### Row count per user (how many state changes have been recorded)

```sql
SELECT username, count(*) AS state_changes
FROM psm_records
GROUP BY username
ORDER BY state_changes DESC;
```

---

### When the monitor last ran

```sql
SELECT timestamp FROM runs ORDER BY id DESC LIMIT 1;
```

---

### All incidents with their detection window

Shows every non-zero state transition alongside the window in which the change occurred.

```sql
SELECT window_start,
       timestamp      AS detected_at,
       username,
       failed_console, failed_other,
       backoff_console, backoff_other
FROM psm_records
WHERE failed_console  > 0
   OR failed_other    > 0
   OR backoff_console > 0
   OR backoff_other   > 0
ORDER BY timestamp DESC;
```

---

### Run history

Useful to confirm the daemon is running on schedule or to investigate a gap in coverage.

```sql
SELECT id,
       timestamp,
       lag(timestamp) OVER (ORDER BY id) AS previous_run,
       round((julianday(timestamp) - julianday(lag(timestamp) OVER (ORDER BY id))) * 24, 2) AS hours_since_prev
FROM runs
ORDER BY id DESC
LIMIT 48;
```

---

## Requirements

- macOS with `psm` available (FileVault-enabled system)
- `sqlite3` — bundled with macOS
- Must run as root (`psm list` requires root)
