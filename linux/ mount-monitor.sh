#!/usr/bin/env bash

#################################################################################
# mount-monitor.sh                                                              #
# Bash script that checks whether one or more expected mountpoints are mounted. #
# Supports optional Checkmk and Grafana alert integration.                      #
# Includes email-based alerts when ALERT_EMAIL is configured.                   #
# Author: Filcu Alexandru                                                       #
#################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

##############################################################
# Mountpoints to monitor.                                    #
#   - Add or remove paths in the MOUNTS array below.         #
#   - Example: MOUNTS=("/mnt/data" "/mnt/backup" "/srv/nfs") #
##############################################################

MOUNTS=("/mnt/data" "/mnt/backup")

#################################################################
# E-Mail alert configuration.                                   #
#   - Set: ALERT_EMAIL to enable email notifications.           #
#   - Example: ALERT_EMAIL="ops@example.com" ./mount-monitor.sh #
#################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal: green = mounted, red = not mounted.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Check that the configured mountpoints are mounted and alert on any that are not.

Options:
  --dry-run   Preview the alert action (and email) without firing it
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
    local body="Mountpoints not mounted on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Mount alert on $(hostname)" "$ALERT_EMAIL"
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

command -v mountpoint >/dev/null 2>&1 || die "mountpoint not found (install util-linux)"
(( ${#MOUNTS[@]} > 0 ))               || die "no mountpoints configured in MOUNTS"

# Check each mountpoint; collect the ones that are not mounted.
down=()
for m in "${MOUNTS[@]}"; do
    if mountpoint -q "$m"; then
        printf '%b%-30s mounted%b\n'     "$GREEN" "$m" "$RST"
    else
        printf '%b%-30s NOT mounted%b\n' "$RED"   "$m" "$RST"
        down+=("$m")
    fi
done

# Alert if any expected mountpoint is missing.
if (( ${#down[@]} > 0 )); then
    alert "${down[*]}"
fi