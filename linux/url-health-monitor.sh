#!/usr/bin/env bash

###################################################################################################
# url-health-monitor.sh                                                                           #
# Bash script that checks one or more URLs and alerts on any that do not return a 2xx/3xx status. #
# Supports optional Checkmk and Grafana alert integration.                                        #
# Includes email-based alerts when ALERT_EMAIL is configured.                                     #
# Author: Filcu Alexandru                                                                         #
###################################################################################################

set -euo pipefail

readonly VERSION="0.1"
readonly TIMEOUT=10
DRY_RUN=0

#######################################################################
# URLs to check.                                                      #
#   - Add or remove URLs in the URLS array below.                     #
#   - Example: URLS=("https://example.com" "https://api.example.com") #
#######################################################################

URLS=("https://example.com")

######################################################################
# E-Mail alert configuration.                                        #
#   - Set: ALERT_EMAIL to enable email notifications.                #
#   - Example: ALERT_EMAIL="ops@example.com" ./url-health-monitor.sh #
######################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Check each URL and alert on any not returning a 2xx/3xx status.

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
    local body="URLs unhealthy on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "URL alert on $(hostname)" "$ALERT_EMAIL"
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

command -v curl >/dev/null 2>&1 || die "curl not found"
(( ${#URLS[@]} > 0 ))           || die "no URLs configured in URLS"

down=()
for url in "${URLS[@]}"; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^[23] ]]; then
        printf '%b%-40s %s%b\n' "$GREEN" "$url" "$code" "$RST"
    else
        printf '%b%-40s %s%b\n' "$RED" "$url" "$code" "$RST"
        down+=("${url} (${code})")
    fi
done

if (( ${#down[@]} > 0 )); then
    alert "${down[*]}"
fi