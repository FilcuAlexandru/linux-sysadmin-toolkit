#!/usr/bin/env bash

##################################################################################
# process-monitor.sh                                                             #
# Bash script for checking whether one or more configured processes are running. #
# Supports optional Checkmk and Grafana alert integration.                       #
# Includes email-based alerts when ALERT_EMAIL is configured.                    #
# Author: Filcu Alexandru                                                        #
##################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

#########################################################
# Processes to monitor.                                 #
#   - Add or remove names in the PROCESSES array below. #
#   - Example: PROCESSES=("nginx" "sshd" "postgres")    #
#########################################################

PROCESSES=("nginx" "sshd")

###################################################################
# E-Mail alert configuration.                                     #
#   - Set: ALERT_EMAIL to enable email notifications.             #
#   - Example: ALERT_EMAIL="ops@example.com" ./process-monitor.sh #
###################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal: green = running, red = not running.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Check whether the configured processes are running and alert on any that are down.

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
    local body="Processes not running on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Process alert on $(hostname)" "$ALERT_EMAIL"
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
command -v pgrep >/dev/null 2>&1 || die "pgrep not found (install procps)"
(( ${#PROCESSES[@]} > 0 ))       || die "no processes configured in PROCESSES"

# Check each process; collect the ones that are not running.
down=()
for proc in "${PROCESSES[@]}"; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        printf '%b%-20s running%b\n'     "$GREEN" "$proc" "$RST"
    else
        printf '%b%-20s not running%b\n' "$RED"   "$proc" "$RST"
        down+=("$proc")
    fi
done

# Alert if any process is down.
if (( ${#down[@]} > 0 )); then
    alert "${down[*]}"
fi
