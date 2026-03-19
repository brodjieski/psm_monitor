#!/bin/zsh

# Title       : psm_monitor.zsh
# Description : Collect psm list unlock-attempt and backoff data for all local users
#               (UID > 500) and store results in a SQLite3 database for historical tracking.
# Author      : Dan Brodjieski
# Date        : 2026-03-18
# Version     : 1.1
# Notes       : Intended to run as root via LaunchDaemon. 
#               is_current = 1 marks the last observed state per user. 
#               To query current state:
#                   SELECT * FROM psm_records WHERE is_current = 1;

DB_DIR="/var/db/psm_monitor"
DB_PATH="${DB_DIR}/psm_monitor.db"

# ---------------------------------------------------------------------------
# Database setup
# ---------------------------------------------------------------------------

setup_db() {
    mkdir -p "$DB_DIR"
    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS runs (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS psm_records (
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
CREATE INDEX IF NOT EXISTS idx_username   ON psm_records(username);
CREATE INDEX IF NOT EXISTS idx_uuid       ON psm_records(uuid);
CREATE INDEX IF NOT EXISTS idx_is_current ON psm_records(is_current);
SQL
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

strip_ansi() {
    sed 's/\x1b\[[0-9;]*[mGKHF]//g'
}

log() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"
}

# ---------------------------------------------------------------------------
# Parse psm list into associative array  psm_data[UUID]="fc|fo|bc|bo"
# ---------------------------------------------------------------------------

parse_psm() {
    local psm_output
    psm_output=$(psm list 2>&1 | strip_ansi)

    local in_block=false
    local current_uuid=""
    local fc="" fo="" bc="" bo=""

    while IFS= read -r line; do

        if [[ "$line" =~ ^-=-=-=-=-=-=- ]]; then
            # Flush previous block
            if [[ -n "$current_uuid" && -n "$fc" ]]; then
                psm_data[$current_uuid]="${fc}|${fo}|${bc}|${bo}"
            fi
            in_block=true
            current_uuid=""; fc=""; fo=""; bc=""; bo=""
            continue
        fi

        [[ "$in_block" == false ]] && continue

        if [[ "$line" =~ "uuid: " ]]; then
            current_uuid=$(echo "$line" | sed -E 's/.*uuid: ([A-Fa-f0-9-]+).*/\1/' | tr 'a-f' 'A-F')
        fi

        if [[ "$line" =~ "failed-unlock-attempts\[console,other\]" ]]; then
            fc=$(echo "$line" | sed -E 's/.*failed-unlock-attempts\[console,other\]: ([0-9]+),.*/\1/')
            fo=$(echo "$line" | sed -E 's/.*failed-unlock-attempts\[console,other\]: [0-9]+, ([0-9]+);.*/\1/')
            bc=$(echo "$line" | sed -E 's/.*backoff\[console,other\]: ([0-9]+),.*/\1/')
            bo=$(echo "$line" | sed -E 's/.*backoff\[console,other\]: [0-9]+, ([0-9]+);.*/\1/')
        fi

    done <<< "$psm_output"

    # Flush final block
    if [[ -n "$current_uuid" && -n "$fc" ]]; then
        psm_data[$current_uuid]="${fc}|${fo}|${bc}|${bo}"
    fi
}

# ---------------------------------------------------------------------------
# Main collection routine
# ---------------------------------------------------------------------------

collect() {
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Record this run and retrieve the previous run's timestamp for use as window_start.
    # Both happen in one transaction so there is no race between reads and writes.
    local window_start
    window_start=$(sqlite3 "$DB_PATH" <<SQL
BEGIN;
INSERT INTO runs (timestamp) VALUES ('${timestamp}');
SELECT timestamp FROM runs ORDER BY id DESC LIMIT 1 OFFSET 1;
COMMIT;
SQL
)

    # Parse psm list
    typeset -gA psm_data
    parse_psm

    if [[ ${#psm_data} -eq 0 ]]; then
        log "ERROR: No entries parsed from psm list — aborting collection." >&2
        return 1
    fi

    # Enumerate local users with UID > 500
    typeset -a users
    while IFS=' ' read -r uname uid_val; do
        users+=("${uname}:${uid_val}")
    done < <(dscl . -list /Users UniqueID | awk '$2 > 500 {print $1, $2}' | sort -k2 -n)

    if [[ ${#users} -eq 0 ]]; then
        log "ERROR: No users with UID > 500 found — aborting collection." >&2
        return 1
    fi

    local inserted=0
    local unchanged=0

    for entry in "${users[@]}"; do
        local uname="${entry%%:*}"
        local uid_val="${entry##*:}"

        local uuid
        uuid=$(dscl . -read "/Users/${uname}" GeneratedUID 2>/dev/null | awk '{print $2}')

        if [[ -z "$uuid" ]]; then
            log "WARN: Could not resolve UUID for '${uname}' — skipping."
            continue
        fi

        local data="${psm_data[$uuid]}"
        if [[ -z "$data" ]]; then
            log "WARN: No psm entry for ${uname} (${uuid}) — skipping."
            continue
        fi

        local fc="${data%%|*}"; data="${data#*|}"
        local fo="${data%%|*}"; data="${data#*|}"
        local bc="${data%%|*}"
        local bo="${data##*|}"

        # Compare against the last recorded state for this user.
        # Only insert a new row if something changed (or there is no prior row).
        local last
        last=$(sqlite3 "$DB_PATH" \
            "SELECT failed_console || '|' || failed_other || '|' || backoff_console || '|' || backoff_other
             FROM psm_records WHERE username = '${uname}' AND is_current = 1 LIMIT 1;")

        if [[ "$last" == "${fc}|${fo}|${bc}|${bo}" ]]; then
            (( unchanged++ ))
            continue
        fi

        # Determine the window_start value to embed in the SQL string
        local ws_sql
        if [[ -n "$window_start" ]]; then
            ws_sql="'${window_start}'"
        else
            ws_sql="NULL"
        fi

        # Values differ (or no prior row) — record the change in a transaction:
        # clear the old is_current flag for this user, insert the new state.
        sqlite3 "$DB_PATH" <<SQL
BEGIN TRANSACTION;
UPDATE psm_records SET is_current = 0 WHERE username = '${uname}';
INSERT INTO psm_records
    (timestamp, window_start, username, uuid, uid, failed_console, failed_other, backoff_console, backoff_other, is_current)
VALUES
    ('${timestamp}', ${ws_sql}, '${uname}', '${uuid}', ${uid_val}, ${fc}, ${fo}, ${bc}, ${bo}, 1);
COMMIT;
SQL
        if [[ -n "$window_start" ]]; then
            log "Change detected for ${uname}: failed[${fc},${fo}] backoff[${bc},${bo}] (window: ${window_start} → ${timestamp})"
        else
            log "Initial state recorded for ${uname}: failed[${fc},${fo}] backoff[${bc},${bo}]"
        fi
        (( inserted++ ))
    done

    log "Run complete — ${inserted} change(s) recorded, ${unchanged} user(s) unchanged."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

if ! command -v sqlite3 &>/dev/null; then
    echo "Error: sqlite3 not found." >&2
    exit 1
fi

setup_db
collect
