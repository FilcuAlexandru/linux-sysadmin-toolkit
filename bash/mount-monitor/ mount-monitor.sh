#!/usr/bin/env bash

#################################################################################
# mount-monitor.sh                                                              #
# Bash script that checks whether one or more expected mountpoints are mounted. #
# Reads /proc/self/mounts first; falls back to 'mountpoint' or 'mount'.         #
# Works on any Linux distribution and inside containers.                        #
# Supports optional Checkmk and Grafana alert integration.                      #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).    #
# Author: Filcu Alexandru                                                       #
#################################################################################

set -euo pipefail
readonly VERSION="0.1"

##############################################################
# Mountpoints to monitor.                                    #
#   - Add or remove paths in the MOUNTS array below.         #
#   - Example: MOUNTS=("/mnt/data" "/mnt/backup" "/srv/nfs") #
##############################################################

MOUNTS=("/mnt/data" "/mnt/backup")

###################################################################
# E-Mail alert configuration.                                     #
#   - ALERT_EMAIL : one or more recipients, space-separated.      #
#                   Leave empty to disable email alerts.           #
#   - Example (single):   ALERT_EMAIL="ops@example.com"           #
#   - Example (multiple): ALERT_EMAIL="ops@ex.com dev@ex.com"     #
#                                                                  #
#   - EMAIL_INTERVAL : seconds between emails (default 3600).     #
#                      Console alerts are always shown.            #
#   - STATE_FILE     : where the last-email timestamp is kept.    #
###################################################################

ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${TMPDIR:-/tmp}/mount-monitor.email.state"

######################################################################
# Logging (optional).                                                #
#   - SCRIPT_DIR is auto-detected; logs go under SCRIPT_DIR/logs/.   #
#   - Set to empty ("") to disable a log.                            #
#                                                                    #
#   - LOG_RETENTION_DAYS : rotate and delete logs older than this.   #
#                          Default 14 (two weeks). Set to 0 to keep  #
#                          logs forever (no rotation).                #
######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/mount-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/mount-monitor-execution.log"
LOG_RETENTION_DAYS="14"

######################################################################
# Host identification.                                               #
#   - Used in alerts, emails, and logs.                              #
#   - Default: system hostname.                                      #
#   - Set a custom label when running in containers where the        #
#     hostname is an auto-generated ID (e.g., "app-prod-01").        #
######################################################################

HOSTNAME_LABEL=""

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Resolve hostname: configured label > $HOSTNAME > hostname(1) > "unknown".
resolve_hostname() {
    if [[ -n "$HOSTNAME_LABEL" ]]; then
        echo "$HOSTNAME_LABEL"
    elif [[ -n "${HOSTNAME:-}" ]]; then
        echo "$HOSTNAME"
    elif command -v hostname >/dev/null 2>&1; then
        hostname
    else
        echo "unknown"
    fi
}
readonly HOST_ID="$(resolve_hostname)"

# Colors only when writing to a terminal: green = mounted, red = not mounted.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

###########
# Logging #
###########

# Best-effort log initialization: create LOG_DIR and touch the files.
# If anything fails, disable that log and warn (never die on log issues).
init_logs() {
    if [[ -n "$ERROR_LOG" || -n "$EXECUTION_LOG" ]] && [[ -n "$LOG_DIR" ]]; then
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            echo "Warning: could not create log directory ${LOG_DIR}; logging disabled" >&2
            ERROR_LOG=""
            EXECUTION_LOG=""
            return
        fi
    fi
    if [[ -n "$ERROR_LOG" ]] && ! touch "$ERROR_LOG" 2>/dev/null; then
        echo "Warning: could not write ${ERROR_LOG}; error logging disabled" >&2
        ERROR_LOG=""
    fi
    if [[ -n "$EXECUTION_LOG" ]] && ! touch "$EXECUTION_LOG" 2>/dev/null; then
        echo "Warning: could not write ${EXECUTION_LOG}; execution logging disabled" >&2
        EXECUTION_LOG=""
    fi
}

# Append a timestamped line to a log file (best-effort, never fatal).
log_to() {
    local file=$1; shift
    [[ -n "$file" ]] || return 0
    printf '%s %s\n' "$(date '+%F %H:%M:%S')" "$*" >> "$file" 2>/dev/null || true
}

################
# Log rotation #
################

# Rotate a single log file if it is older than LOG_RETENTION_DAYS, then
# prune its archived copies that have exceeded the retention window.
rotate_one() {
    local file=$1
    [[ -n "$file" && -f "$file" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))   || return 0

    # find(1) is needed for mtime checks; skip rotation if unavailable
    # (e.g., minimal containers without findutils).
    command -v find >/dev/null 2>&1 || return 0

    local base dir
    base=$(basename "$file")
    dir=$(dirname "$file")

    # Rotate the active log if its last modification is older than the window.
    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$file" "${file}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi

    # Prune archived copies older than the window (glob: basename.*).
    find "$dir" -maxdepth 1 -type f -name "${base}.*" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# Rotate all active logs.
rotate_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    rotate_one "$ERROR_LOG"
    rotate_one "$EXECUTION_LOG"
}

########################
# E-Mail rate-limiting #
########################

# Return 0 if enough time has passed since the last email; 1 otherwise.
# Missing or corrupt state file -> treat as "never sent" -> allow.
should_send_email() {
    [[ -r "$STATE_FILE" ]] || return 0
    local last now
    last=$(< "$STATE_FILE") || return 0
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s)
    (( now - last >= EMAIL_INTERVAL ))
}

# Record that an email was just sent (best-effort; warn but don't fail).
mark_email_sent() {
    if ! date +%s > "$STATE_FILE" 2>/dev/null; then
        echo "Warning: could not write state file ${STATE_FILE}" >&2
    fi
}

# Print how long since the last email (or "never").
last_email_age() {
    [[ -r "$STATE_FILE" ]] || { echo "never"; return; }
    local last
    last=$(< "$STATE_FILE") || { echo "never"; return; }
    [[ "$last" =~ ^[0-9]+$ ]] || { echo "never"; return; }
    echo "$(( $(date +%s) - last ))s ago"
}

#########
# Alert #
#########

# Emit console alerts, log to ERROR_LOG, and optionally send email.
# Designed as an integration point for external monitoring systems
# (Checkmk, Grafana, Prometheus, etc.).
alert() {
    local detail="$*"
    local body="Mountpoints not mounted on ${HOST_ID}: ${detail}"

    log_to "$ERROR_LOG" "ALERT ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        if [[ -n "$ALERT_EMAIL" ]]; then
            if should_send_email; then
                echo "[dry-run] would email: ${ALERT_EMAIL} (last sent: $(last_email_age))"
            else
                echo "[dry-run] would skip email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)"
            fi
        fi
        return 0
    fi

    echo "ALERT: ${body}" >&2

    [[ -n "$ALERT_EMAIL" ]] || return 0

    if ! command -v mail >/dev/null 2>&1; then
        echo "Warning: ALERT_EMAIL is set but 'mail' command was not found" >&2
        return 0
    fi

    if should_send_email; then
        # Word splitting on $ALERT_EMAIL is intentional: each space-separated
        # address becomes a separate argument to mail(1).
        # shellcheck disable=SC2086
        echo "$body" | mail -s "Mount alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

###################
# Mount detection #
###################

# Return 0 if $1 is currently a mountpoint, 1 otherwise.
# Source preference: /proc/self/mounts -> mountpoint(1) -> mount(1).
is_mounted() {
    local target=$1

    # 1) Kernel truth: /proc/self/mounts.
    #    Present on every Linux system, including containers.
    if [[ -r /proc/self/mounts ]]; then
        local _dev mp _rest
        while read -r _dev mp _rest; do
            if [[ "$mp" == "$target" ]]; then
                return 0
            fi
        done < /proc/self/mounts
        return 1
    fi

    # 2) mountpoint(1) from util-linux.
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$target" 2>/dev/null
        return $?
    fi

    # 3) mount(1): scan its output (column 3 = mountpoint).
    if command -v mount >/dev/null 2>&1; then
        mount 2>/dev/null | awk -v t="$target" '$3 == t { found = 1 } END { exit !found }'
        return $?
    fi

    die "no source available to check mount state (no /proc/self/mounts, no mountpoint, no mount)"
}

#######
# CLI #
#######

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Check that the configured mountpoints are mounted and alert on any that are not.
Email alerts are rate-limited to one every EMAIL_INTERVAL seconds (default 3600).
Console alerts are not rate-limited.

Options:
  --dry-run   Preview the alert action (and email decision) without firing it
  --version   Show version and exit
  --help      Show this help and exit

Logs: by default in a 'logs/' directory next to this script.
      Rotated and pruned every LOG_RETENTION_DAYS (default 14).
      Set ERROR_LOG / EXECUTION_LOG to "" to disable.

Email: set ALERT_EMAIL in the script to enable (one or more recipients).
       Requires a working 'mail' command and a configured MTA/relay.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

# Parse arguments.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) echo "Version=${VERSION}"; exit 0 ;;
        --help)    usage; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

########
# Main #
########

(( ${#MOUNTS[@]} > 0 )) || die "no mountpoints configured in MOUNTS"

init_logs
rotate_logs
log_to "$EXECUTION_LOG" "START [${HOST_ID}] checking ${#MOUNTS[@]} mount(s): ${MOUNTS[*]}"

# Check each mountpoint; collect the ones that are not mounted.
down=()
for m in "${MOUNTS[@]}"; do
    if is_mounted "$m"; then
        printf '%b%-30s mounted%b\n' "$GREEN" "$m" "$RST"
    else
        printf '%b%-30s NOT mounted%b\n' "$RED" "$m" "$RST"
        down+=("$m")
    fi
done

if (( ${#down[@]} > 0 )); then
    log_to "$EXECUTION_LOG" "RESULT ${#down[@]} unmounted: ${down[*]}"
    alert "${down[*]}"
else
    log_to "$EXECUTION_LOG" "RESULT all mounted"
fi

log_to "$EXECUTION_LOG" "END"