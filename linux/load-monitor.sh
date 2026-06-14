#!/usr/bin/env bash

################################################################################
# load-monitor.sh                                                              #
# Bash script for monitoring system load average against a per-core threshold. #
# Supports optional Checkmk and Grafana alert integration.                     #
# Includes email-based alerts when ALERT_EMAIL is configured.                  #
# Author: Filcu Alexandru                                                      #
################################################################################

set -euo pipefail
export LC_ALL=C   # stable decimal separator regardless of locale

readonly VERSION="0.1"
readonly LOAD_RATIO=1.5
DRY_RUN=0

################################################################
# E-Mail alert configuration.                                  #
#   - Set: ALERT_EMAIL to enable email notifications.          #
#   - Example: ALERT_EMAIL="ops@example.com" ./load-monitor.sh #
################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Show load average and alert when the 1-minute load exceeds cores x ${LOAD_RATIO}.

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
    local body="High load average on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Load alert on $(hostname)" "$ALERT_EMAIL"
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

# Read 1-minute load average and CPU core count.
cores=$(nproc 2>/dev/null || echo 1)
read -r load1 load5 load15 _ < /proc/loadavg || die "could not read /proc/loadavg"

# limit = cores * LOAD_RATIO; comparison in awk (float math).
limit=$(awk -v c="$cores" -v r="$LOAD_RATIO" 'BEGIN { printf "%.2f", c * r }')
over=$(awk -v l="$load1" -v lim="$limit" 'BEGIN { print (l > lim) ? 1 : 0 }')

if (( over )); then
    printf 'Load average: %b%s%b %s %s (cores: %s, limit: %s)\n' "$RED" "$load1" "$RST" "$load5" "$load15" "$cores" "$limit"
    alert "1-min load ${load1} over limit ${limit} (cores ${cores})"
else
    printf 'Load average: %s %s %s (cores: %s, limit: %s)\n' "$load1" "$load5" "$load15" "$cores" "$limit"
fi