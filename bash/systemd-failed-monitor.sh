#!/usr/bin/env bash

################################################################################################
# systemd-failed-monitor.sh                                                                    #
# Bash script that lists failed systemd units and alerts when any unit is in the failed state. #
# Supports optional Checkmk and Grafana alert integration.                                     #
# Includes email-based alerts when ALERT_EMAIL is configured.                                  #
# Author: Filcu Alexandru                                                                      #
################################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

##########################################################################
# E-Mail alert configuration.                                            #
#   - Set: ALERT_EMAIL to enable email notifications.                    #
#   - Example: ALERT_EMAIL="ops@example.com" ./systemd-failed-monitor.sh #
##########################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

List failed systemd units and alert if any are in the failed state.

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
    local body="Failed systemd units on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Systemd alert on $(hostname)" "$ALERT_EMAIL"
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

command -v systemctl >/dev/null 2>&1 || die "systemctl not found"

# List failed units (first column = unit name).
failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk 'NF {print $1}')

if [[ -z "$failed" ]]; then
    printf '%bNo failed units%b\n' "$GREEN" "$RST"
else
    echo "Failed units:"
    while IFS= read -r unit; do
        printf '%b  %s%b\n' "$RED" "$unit" "$RST"
    done <<< "$failed"
    alert "$(echo $failed)"
fi