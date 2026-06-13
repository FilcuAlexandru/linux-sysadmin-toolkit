#!/usr/bin/env bash

#########################################################################
# service-watchdog.sh                                                   #
# Bash script that restarts any configured service that is not running. #
# Supports optional Checkmk and Grafana alert integration.              #
# Includes email-based alerts when ALERT_EMAIL is configured.           #
# Author: Filcu Alexandru                                               #
#########################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

########################################################
# Services to manage.                                  #
#   - Add or remove names in the SERVICES array below. #
#   - Example: SERVICES=("nginx" "sshd" "postgres")    #
########################################################
SERVICES=("nginx" "sshd")

####################################################################
# E-Mail alert configuration.                                      #
#   - Set: ALERT_EMAIL to enable email notifications.              #
#   - Example: ALERT_EMAIL="ops@example.com" ./service-watchdog.sh #
####################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal: green = running, red = not running.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Restart any SERVICES entry that is not running, with optional alerting.

Options:
  --dry-run   Preview the action (and email) without performing it
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
    local body="Service action on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Service alert on $(hostname)" "$ALERT_EMAIL"
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
command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
command -v pgrep     >/dev/null 2>&1 || die "pgrep not found (install procps)"
(( ${#SERVICES[@]} > 0 ))            || die "no services configured in SERVICES"

# Restart every configured service that is not currently running.
restarted=()
for svc in "${SERVICES[@]}"; do
    if pgrep -x "$svc" >/dev/null 2>&1; then
        printf '%b%-20s running%b\n' "$GREEN" "$svc" "$RST"
    else
        printf '%b%-20s not running%b\n' "$RED" "$svc" "$RST"
        if (( DRY_RUN )); then
            echo "[dry-run] would restart: $svc"
        else
            systemctl restart "$svc" || die "failed to restart $svc"
            echo "$svc restarted"
        fi
        restarted+=("$svc")
    fi
done

if (( ${#restarted[@]} > 0 )); then
    alert "restarted (were down): ${restarted[*]}"
fi