#!/usr/bin/env bash

#################################################################################################
# directory-backup.sh                                                                           #
# Bash script that creates a timestamped .tar.gz backup of a directory and prunes old archives. #
# Supports optional Checkmk and Grafana alert integration.                                      #
# Includes email-based alerts when ALERT_EMAIL is configured.                                   #
# Author: Filcu Alexandru                                                                       #
#################################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

###################################################################
# Backup configuration (can be overridden via environment).       #
#   - SOURCE         : directory to back up.                      #
#   - BACKUP_DIR     : where archives are stored.                 #
#   - RETENTION_DAYS : delete archives older than this many days. #
###################################################################

SOURCE="${SOURCE:-/path/to/directory}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

####################################################################
# E-Mail alert configuration.                                      #
#   - Set: ALERT_EMAIL to enable email notifications.              #
#   - Example: ALERT_EMAIL="ops@example.com" ./directory-backup.sh #
####################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RST=$'\e[0m'; else GREEN=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Create a timestamped .tar.gz backup of SOURCE in BACKUP_DIR and prune old archives.

Options:
  --dry-run   Preview the backup and the retention cleanup without doing them
  --version   Show version and exit
  --help      Show this help and exit

Email: set ALERT_EMAIL (in the script or via environment) to enable.
       Requires a working 'mail' command and a configured MTA/relay.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

# Emit console alerts and optionally send email when ALERT_EMAIL is configured.
# Designed as an integration point for external monitoring systems (Checkmk, Grafana, etc.).
alert() {
    local detail="$*"
    local body="Backup failed on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Backup alert on $(hostname)" "$ALERT_EMAIL"
        else
            echo "Warning: ALERT_EMAIL is set but 'mail' command was not found" >&2
        fi
    fi
}

# Parse arguments.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) echo "Version=${VERSION}"; exit 0 ;;
        --help)    usage; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

# Sanity checks.
command -v tar >/dev/null 2>&1 || die "tar not found"
[[ -d "$SOURCE" ]]             || die "source directory not found: $SOURCE"

# Build the timestamped archive name (date + time, so several runs per day don't collide).
timestamp=$(date +%F_%H%M%S)
archive="${BACKUP_DIR}/backup_${timestamp}.tar.gz"

# Dry-run: preview the archive and the retention cleanup, then stop.
if (( DRY_RUN )); then
    echo "[dry-run] would archive '${SOURCE}' -> ${archive}"
    old=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' -mtime +"$RETENTION_DAYS" 2>/dev/null || true)
    if [[ -n "$old" ]]; then
        echo "[dry-run] would delete archives older than ${RETENTION_DAYS} days:"
        echo "$old"
    fi
    exit 0
fi

# Make sure the destination exists.
mkdir -p "$BACKUP_DIR" || die "cannot create backup directory: $BACKUP_DIR"

# Create the archive; alert and stop on failure.
if ! tar -czf "$archive" "$SOURCE"; then
    alert "tar failed while backing up ${SOURCE}"
    die "backup failed"
fi

size=$(du -h "$archive" 2>/dev/null | cut -f1)
printf '%bBackup created:%b %s (%s)\n' "$GREEN" "$RST" "$archive" "$size"

# Retention: remove our own archives older than RETENTION_DAYS (the glob keeps it safe).
removed=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' -mtime +"$RETENTION_DAYS" -print -delete)
if [[ -n "$removed" ]]; then
    echo "Removed archives older than ${RETENTION_DAYS} days:"
    echo "$removed"
fi