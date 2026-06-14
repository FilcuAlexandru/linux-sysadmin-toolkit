#!/usr/bin/env bash

######################################################################################
# log-cleanup.sh                                                                     #
# Bash script that deletes log files older than a retention window from a directory. #
# Includes email-based alerts when ALERT_EMAIL is configured (on removal errors).    #
# Author: Filcu Alexandru                                                            #
######################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

##################################################################
# Cleanup configuration (all can be overridden via environment). #
#   - LOG_DIR        : directory to clean.                       #
#   - PATTERN        : filename glob to match.                   #
#   - RETENTION_DAYS : delete files older than this many days.   #
##################################################################
LOG_DIR="${LOG_DIR:-/path/to/logs}"
PATTERN="${PATTERN:-*.log}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

###############################################################
# E-Mail alert configuration.                                 #
#   - Set: ALERT_EMAIL to enable email notifications.         #
#   - Example: ALERT_EMAIL="ops@example.com" ./log-cleanup.sh #
###############################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Delete files matching PATTERN older than RETENTION_DAYS in LOG_DIR.

Options:
  --dry-run   Preview the deletions without performing them
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
    local body="Log cleanup problem on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Log cleanup alert on $(hostname)" "$ALERT_EMAIL"
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

[[ -d "$LOG_DIR" ]] || die "log directory not found: $LOG_DIR"

# Find matching files older than the window (bounded by dir + pattern + type f).
mapfile -t old < <(find "$LOG_DIR" -maxdepth 1 -type f -name "$PATTERN" -mtime +"$RETENTION_DAYS" 2>/dev/null)

if (( ${#old[@]} == 0 )); then
    echo "Nothing to clean in ${LOG_DIR} (pattern '${PATTERN}', older than ${RETENTION_DAYS} days)"
    exit 0
fi

if (( DRY_RUN )); then
    echo "[dry-run] would delete ${#old[@]} file(s) from ${LOG_DIR}:"
    printf '  %s\n' "${old[@]}"
    exit 0
fi

removed=0; fail=0
for f in "${old[@]}"; do
    if rm -f -- "$f"; then echo "Removed: $f"; removed=$((removed + 1)); else echo "Failed to remove: $f" >&2; fail=1; fi
done
echo "Removed ${removed} of ${#old[@]} file(s) older than ${RETENTION_DAYS} days from ${LOG_DIR}."
if (( fail )); then alert "some files could not be removed from ${LOG_DIR}"; fi