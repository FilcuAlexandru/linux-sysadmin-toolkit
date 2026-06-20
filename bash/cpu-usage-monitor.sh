#!/usr/bin/env bash

###############################################################################################
# cpu-usage-monitor.sh                                                                        #
# Bash script for monitoring CPU usage and alerting when it exceeds a configurable threshold. #
# Supports optional Checkmk and Grafana alert integration.                                    #
# Includes email-based alerts when ALERT_EMAIL is configured.                                 #
# Author: Filcu Alexandru                                                                     #
###############################################################################################

set -euo pipefail
export LC_ALL=C # stable decimal separator regardless of locale

readonly VERSION="0.1"
readonly THRESHOLD=80
DRY_RUN=0

#####################################################################
# E-Mail alert configuration.                                       #
#   - Set: ALERT_EMAIL to enable email notifications.               #
#   - Example: ALERT_EMAIL="ops@example.com" ./cpu-usage-monitor.sh #
#####################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then RED=$'\e[31m'; RST=$'\e[0m'; else RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Show current CPU usage and alert when it exceeds ${THRESHOLD}%.

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
    local body="CPU usage above ${THRESHOLD}% on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "CPU alert on $(hostname)" "$ALERT_EMAIL"
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

# Read CPU usage once: user + system, like the original 'top | awk' one-liner.
# The float comparison is done in awk to avoid bash integer-only math.
read -r usage_pct over < <(
    top -bn1 | awk -v thr="$THRESHOLD" '
        /Cpu\(s\)/ {
            pct = $2 + $4
            printf "%.1f %d\n", pct, (pct > thr ? 1 : 0)
        }'
) || die "could not read CPU usage"
[[ -n "$usage_pct" ]] || die "could not parse CPU usage from top"

# Print the value (red when above the threshold) and alert if needed.
if (( over )); then
    printf 'CPU Usage: %b%s%%%b\n' "$RED" "$usage_pct" "$RST"
    alert "${usage_pct}%"
else
    printf 'CPU Usage: %s%%\n' "$usage_pct"
fi