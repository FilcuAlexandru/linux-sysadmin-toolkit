#!/usr/bin/env bash

####################################################################################################
# cert-expiry-monitor.sh                                                                           #
# Bash script that checks a certificate (file or host:port) and alerts when it is about to expire. #
# Supports optional Checkmk and Grafana alert integration.                                         #
# Includes email-based alerts when ALERT_EMAIL is configured.                                      #
# Author: Filcu Alexandru                                                                          #
####################################################################################################

set -euo pipefail
export LC_ALL=C # ensures date -d parses the English month names openssl prints

readonly VERSION="0.1"
readonly THRESHOLD_DAYS=30
DRY_RUN=0

###########################################################################
# Certificate target (TARGET can be overridden via environment).          #
#   - A local file path, or a remote host:port.                           #
#   - Example: TARGET="example.com:443"   or   TARGET="/etc/ssl/cert.pem" #
###########################################################################

TARGET="${TARGET:-example.com:443}"

#######################################################################
# E-Mail alert configuration.                                         #
#   - Set: ALERT_EMAIL to enable email notifications.                 #
#   - Example: ALERT_EMAIL="ops@example.com" ./cert-expiry-monitor.sh #
#######################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"

# Use colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Check a certificate (file or host:port) and alert if it expires within ${THRESHOLD_DAYS} days.

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
    local body="Certificate expiring soon on $(hostname): ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$ALERT_EMAIL" ]] && echo "[dry-run] would email: ${ALERT_EMAIL}"
        return 0
    fi

    echo "ALERT: ${body}" >&2

    if [[ -n "$ALERT_EMAIL" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$body" | mail -s "Certificate alert on $(hostname)" "$ALERT_EMAIL"
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

command -v openssl >/dev/null 2>&1 || die "openssl not found"

# Read the certificate end date: local file, or remote host:port.
if [[ -f "$TARGET" ]]; then
    enddate=$(openssl x509 -enddate -noout -in "$TARGET" 2>/dev/null | cut -d= -f2)
else
    host=${TARGET%%:*}
    port=${TARGET##*:}
    [[ "$port" == "$host" ]] && port=443
    enddate=$(echo | openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null \
              | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)
fi
[[ -n "$enddate" ]] || die "could not read certificate from: $TARGET"

# Compute days until expiry.
exp_epoch=$(date -d "$enddate" +%s 2>/dev/null) || die "could not parse end date: $enddate"
days=$(( (exp_epoch - $(date +%s)) / 86400 ))

if (( days < THRESHOLD_DAYS )); then
    printf 'Certificate %s expires in %b%s days%b (%s)\n' "$TARGET" "$RED" "$days" "$RST" "$enddate"
    alert "${TARGET} expires in ${days} days (${enddate})"
else
    printf 'Certificate %s expires in %s days (%s)\n' "$TARGET" "$days" "$enddate"
fi