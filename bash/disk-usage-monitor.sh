#!/usr/bin/env bash

#####################################################################################################################
# disk-usage-monitor.sh                                                                                             #
# Bash script for monitoring filesystem disk usage and highlighting filesystems exceeding a configurable threshold. #
# Supports optional Checkmk and Grafana alert integration.                                                          #
# Includes email-based alerts when ALERT_EMAIL is configured.                                                       #
# Author: Filcu Alexandru                                                                                           #
#####################################################################################################################

set -euo pipefail

readonly VERSION="0.1"
readonly THRESHOLD=80
DRY_RUN=0

######################################################################
# E-Mail alert configuration.                                        #
#   - Set: ALERT_EMAIL to enable email notifications.                #
#   - Example: ALERT_EMAIL="ops@example.com" ./disk-usage-monitor.sh #
######################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then RED=$'\e[31m'; RST=$'\e[0m'; else RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Show disk usage per filesystem and highlight anything above ${THRESHOLD}%.

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
    local list="$*"
    local body="Disk usage above ${THRESHOLD}% on $(hostname): ${list}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert for: ${list}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Disk alert on $(hostname)" "$ALERT_EMAIL"
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

# Read disk usage once.
report=$(df -h) || die "could not run df"
[[ -n "$report" ]] || die "df returned no output"

# Print the table, coloring red any filesystem above the threshold.
awk -v thr="$THRESHOLD" -v red="$RED" -v rst="$RST" '
    NR == 1 { print; next } # header, untouched
    {
        use = 0
        for (i = 1; i <= NF; i++) if ($i ~ /%$/) { use = $i + 0; break }
        if (use > thr) print red $0 rst; else print $0
    }' <<< "$report"

# Collect filesystems above the threshold and alert if any.
breached=$(awk -v thr="$THRESHOLD" '
    NR == 1 { next }
    {
        use = 0
        for (i = 1; i <= NF; i++) if ($i ~ /%$/) { use = $i + 0; break }
        if (use > thr) printf "%s ", $NF
    }' <<< "$report")

if [[ -n "$breached" ]]; then
    alert "${breached% }"
fi