#!/usr/bin/env bash

######################################################################################################
# tmp-cleanup.sh                                                                                     #
# Bash script that removes files older than a given age from a temp directory and prunes empty dirs. #
# Includes email-based alerts when ALERT_EMAIL is configured (on removal errors).                    #
# Author: Filcu Alexandru                                                                            #
######################################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

##################################################################
# Cleanup configuration (all can be overridden via environment). #
#   - TMP_DIR  : directory to clean.                             #
#   - AGE_DAYS : delete files older than this many days.         #
##################################################################

TMP_DIR="${TMP_DIR:-/tmp}"
AGE_DAYS="${AGE_DAYS:-7}"

###############################################################
# E-Mail alert configuration.                                 #
#   - Set: ALERT_EMAIL to enable email notifications.         #
#   - Example: ALERT_EMAIL="ops@example.com" ./tmp-cleanup.sh #
###############################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Delete files older than AGE_DAYS in TMP_DIR, then prune empty directories.

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
    local body="Temp cleanup problem on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Temp cleanup alert on $(hostname)" "$ALERT_EMAIL"
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

[[ -d "$TMP_DIR" ]] || die "directory not found: $TMP_DIR"

mapfile -t old < <(find "$TMP_DIR" -mindepth 1 -type f -mtime +"$AGE_DAYS" 2>/dev/null)

if (( DRY_RUN )); then
    if (( ${#old[@]} == 0 )); then
        echo "[dry-run] nothing older than ${AGE_DAYS} days in ${TMP_DIR}"
    else
        echo "[dry-run] would delete ${#old[@]} file(s) from ${TMP_DIR}:"
        printf '  %s\n' "${old[@]}"
        echo "[dry-run] would then prune empty directories"
    fi
    exit 0
fi

removed=0; fail=0
for f in "${old[@]}"; do
    if rm -f -- "$f"; then removed=$((removed + 1)); else fail=1; fi
done
find "$TMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
echo "Removed ${removed} file(s) older than ${AGE_DAYS} days from ${TMP_DIR}; pruned empty directories."
if (( fail )); then alert "some files could not be removed from ${TMP_DIR}"; fi