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

######################################################
# Script directory.                                  #
#   - Auto-detected.                                 #
#   - Used as default base for state files and logs. # 
#   - Override if needed.                            #
######################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

##############################################################
# Mountpoints to monitor.                                    #
#   - Add or remove paths in the MOUNTS array below.         #
#   - Example: MOUNTS=("/mnt/data" "/mnt/backup" "/srv/nfs") #
##############################################################

MOUNTS=("/mnt/data" "/mnt/backup")

################################################################
# E-Mail alert configuration.                                  #
#   - ALERT_EMAIL : one or more recipients, space-separated.   #
#                   Leave empty to disable email alerts.       #
#   - Example (single):   ALERT_EMAIL="ops@example.com"        #
#   - Example (multiple): ALERT_EMAIL="ops@ex.com dev@ex.com"  #
#                                                              #
#   - EMAIL_INTERVAL : seconds between emails (default 3600).  #
#                      Console alerts are always shown.        #
#   - STATE_FILE     : where the last-email timestamp is kept. #
################################################################

ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/mount-monitor.email.state"

#####################################################################
# Logging (optional).                                               #
#   - Logs go under LOG_DIR (default: SCRIPT_DIR/logs/).            #
#   - Set to empty ("") to disable a log.                           #
#                                                                   #
#   - LOG_RETENTION_DAYS : rotate and delete logs older than this.  #
#                          Default 14 (two weeks). Set to 0 to keep #
#                          logs forever (no rotation).              #
#####################################################################

LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/mount-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/mount-monitor-execution.log"
LOG_RETENTION_DAYS="14"

###############################################################
# Host identification.                                        #
#   - Used in alerts, emails, and logs.                       #
#   - Default: system hostname.                               #
#   - Set a custom label when running in containers where the #
#     hostname is an auto-generated ID (e.g., "app-prod-01"). #
###############################################################

HOSTNAME_LABEL=""

################################################################
# Maintenance mode.                                            #
#   - Alerts are suppressed while maintenance is active.       #
#   - Toggle with: ./mount-monitor.sh --maintenance            #
#   - State is stored in MAINTENANCE_FILE (auto-managed).      #
################################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/mount-monitor.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/mount-monitor.lock"

#########################################################
# Status tracking.                                      #
#   - Prevents repeated alerts while mounts stay down.  #
#   - Sends a recovery email when all mounts come back. #
#   - Possible values stored in this file: OK, ALERT.   #
#########################################################

STATUS_FILE="${SCRIPT_DIR}/mount-monitor.status"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0
PROC_READ=0
declare -A mounted

########################
# Hostname resolution. #
########################

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

# Colors only when writing to a terminal.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

############
# Logging. #
############

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

#################
# Log rotation. #
#################

# Rotate a single log file if older than LOG_RETENTION_DAYS, then prune archives.
rotate_one() {
    local file=$1
    [[ -n "$file" && -f "$file" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))   || return 0
    command -v find >/dev/null 2>&1 || return 0

    local base dir
    base=$(basename "$file")
    dir=$(dirname "$file")

    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$file" "${file}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi

    find "$dir" -maxdepth 1 -type f -name "${base}.*" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

rotate_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    rotate_one "$ERROR_LOG"
    rotate_one "$EXECUTION_LOG"
}

############
# Locking. #
############

# Prevent overlapping runs (cron safety).
# Skipped gracefully if flock is unavailable or the file cannot be created.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    touch "$LOCK_FILE" 2>/dev/null   || return 0
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0
}

#########################
# E-Mail rate-limiting. #
#########################

# Return 0 if enough time has passed since the last email; 1 otherwise.
should_send_email() {
    [[ -r "$STATE_FILE" ]] || return 0
    local last now
    last=$(< "$STATE_FILE") || return 0
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s)
    (( now - last >= EMAIL_INTERVAL ))
}

mark_email_sent() {
    date +%s > "$STATE_FILE" 2>/dev/null || true
}

last_email_age() {
    [[ -r "$STATE_FILE" ]] || { echo "never"; return; }
    local last
    last=$(< "$STATE_FILE") || { echo "never"; return; }
    [[ "$last" =~ ^[0-9]+$ ]] || { echo "never"; return; }
    echo "$(( $(date +%s) - last ))s ago"
}

####################
# Status tracking. #
####################

get_status() {
    [[ -r "$STATUS_FILE" ]] || { echo "OK"; return; }
    local status
    status=$(< "$STATUS_FILE") || { echo "OK"; return; }
    case "$status" in
        OK|ALERT) echo "$status" ;;
        *)        echo "OK" ;;
    esac
}

set_status() {
    echo "$1" > "$STATUS_FILE" 2>/dev/null || true
}

#############
# Recovery. #
#############

send_recovery_mail() {
    [[ -n "$ALERT_EMAIL" ]]              || return 0
    command -v mail >/dev/null 2>&1       || return 0

    local body="All monitored mountpoints are mounted again on ${HOST_ID}"

    if (( DRY_RUN )); then
        echo "[dry-run] would send recovery email to: ${ALERT_EMAIL}"
        return 0
    fi

    # shellcheck disable=SC2086
    echo "$body" | mail -s "Mount recovery on ${HOST_ID}" $ALERT_EMAIL
    log_to "$ERROR_LOG" "RECOVERY EMAIL sent to ${ALERT_EMAIL}"
}

##########
# Alert. #
##########

# Emit console alerts, log to ERROR_LOG, and optionally send email.
# Designed as an integration point for Checkmk, Grafana, Prometheus, etc.
alert() {
    local detail="$*"
    local body="Mountpoints not mounted on ${HOST_ID}: ${detail}"

    # Maintenance mode: suppress alerts but log the suppression.
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        log_to "$EXECUTION_LOG" "Maintenance mode active; alert suppressed"
        return 0
    fi

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
        # shellcheck disable=SC2086
        echo "$body" | mail -s "Mount alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

####################
# Mount detection. #
####################

# Return 0 if $1 is currently a mountpoint, 1 otherwise.
# Source preference: /proc/self/mounts (cached) -> mountpoint(1) -> mount(1).
is_mounted() {
    local target=$1

    # Fast path: associative array populated from /proc/self/mounts.
    if (( PROC_READ )); then
        if [[ ${mounted["$target"]+x} ]]; then
            return 0
        fi
        return 1
    fi

    # Fallback 1: mountpoint(1) from util-linux.
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$target" 2>/dev/null
        return $?
    fi

    # Fallback 2: mount(1) output parsed with awk.
    if command -v mount >/dev/null 2>&1; then
        mount 2>/dev/null | awk -v t="$target" '$3 == t { found = 1 } END { exit !found }'
        return $?
    fi

    die "no source available to check mount state (no /proc/self/mounts, no mountpoint, no mount)"
}

##########################
# Maintenance toggle.    #
##########################

toggle_maintenance() {
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        rm -f "$MAINTENANCE_FILE"
        echo "Maintenance mode disabled"
        log_to "$EXECUTION_LOG" "Maintenance mode disabled by user"
    else
        touch "$MAINTENANCE_FILE" 2>/dev/null || die "could not create ${MAINTENANCE_FILE}"
        echo "Maintenance mode enabled"
        log_to "$EXECUTION_LOG" "Maintenance mode enabled by user"
    fi
}

########################
# Prerequisites check. #
########################

# Show the status of every dependency and config setting.
# Called automatically when --dry-run is used.
check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"

    # Mount source chain.
    if [[ -r /proc/self/mounts ]]; then
        printf '  %-28s %b\n' "/proc/self/mounts" "$ok"
    else
        printf '  %-28s %b\n' "/proc/self/mounts" "$miss"
    fi
    if command -v mountpoint >/dev/null 2>&1; then
        printf '  %-28s %b (fallback)\n' "mountpoint" "$ok"
    else
        printf '  %-28s %b (fallback)\n' "mountpoint" "$miss"
    fi
    if command -v mount >/dev/null 2>&1; then
        printf '  %-28s %b (fallback)\n' "mount" "$ok"
    else
        printf '  %-28s %b (fallback)\n' "mount" "$miss"
    fi

    # Optional tools.
    if command -v mail >/dev/null 2>&1; then
        printf '  %-28s %b\n' "mail" "$ok"
    else
        printf '  %-28s %b (email will not work)\n' "mail" "$miss"
    fi
    if command -v flock >/dev/null 2>&1; then
        printf '  %-28s %b\n' "flock" "$ok"
    else
        printf '  %-28s %b (locking disabled)\n' "flock" "$miss"
    fi
    if command -v find >/dev/null 2>&1; then
        printf '  %-28s %b\n' "find" "$ok"
    else
        printf '  %-28s %b (log rotation disabled)\n' "find" "$miss"
    fi

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Host ID:" "$HOST_ID"
    printf '  %-28s %s\n' "Mounts:" "${MOUNTS[*]}"
    if [[ -n "$ALERT_EMAIL" ]]; then
        printf '  %-28s %s\n' "Email:" "$ALERT_EMAIL"
        printf '  %-28s %ss\n' "Email interval:" "$EMAIL_INTERVAL"
    else
        printf '  %-28s %b\n' "Email:" "$dis"
    fi
    if [[ -n "$ERROR_LOG" ]]; then
        printf '  %-28s %s\n' "Error log:" "$ERROR_LOG"
    else
        printf '  %-28s %b\n' "Error log:" "$dis"
    fi
    if [[ -n "$EXECUTION_LOG" ]]; then
        printf '  %-28s %s\n' "Execution log:" "$EXECUTION_LOG"
    else
        printf '  %-28s %b\n' "Execution log:" "$dis"
    fi
    printf '  %-28s %s days\n' "Log retention:" "$LOG_RETENTION_DAYS"

    echo
    echo "State:"
    printf '  %-28s %s\n' "Current status:" "$(get_status)"
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        printf '  %-28s %b\n' "Maintenance mode:" "${RED}ACTIVE${RST}"
    else
        printf '  %-28s %s\n' "Maintenance mode:" "off"
    fi
    printf '  %-28s %s\n' "Last email:" "$(last_email_age)"
    if [[ -w "$(dirname "$LOCK_FILE")" ]]; then
        printf '  %-28s %b\n' "Lock directory writable:" "$ok"
    else
        printf '  %-28s %b\n' "Lock directory writable:" "$miss"
    fi
    echo
}

########
# CLI. #
########

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Check that the configured mountpoints are mounted and alert on any that are not.
Sends a recovery email when all mounts come back after an alert.
Email alerts are rate-limited to one every EMAIL_INTERVAL seconds (default 3600).
Console alerts are not rate-limited.

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit

Logs: by default in a 'logs/' directory next to this script.
      Rotated and pruned every LOG_RETENTION_DAYS (default 14).
      Set ERROR_LOG / EXECUTION_LOG to "" to disable.

Email: set ALERT_EMAIL in the script to enable (one or more recipients).
       Requires a working 'mail' command and a configured MTA/relay.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --maintenance) toggle_maintenance; exit 0 ;;
        --version)     echo "Version=${VERSION}"; exit 0 ;;
        --help)        usage; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
done

#########
# Main. #
#########

(( ${#MOUNTS[@]} > 0 )) || die "no mountpoints configured in MOUNTS"

acquire_lock
init_logs
rotate_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}] checking ${#MOUNTS[@]} mount(s): ${MOUNTS[*]}"

# Read /proc/self/mounts once into an associative array for fast lookups.
if [[ -r /proc/self/mounts ]]; then
    PROC_READ=1
    while read -r _dev mp _rest; do
        mounted["$mp"]=1
    done < /proc/self/mounts
fi

# Check each mountpoint.
down=()
for m in "${MOUNTS[@]}"; do
    if is_mounted "$m"; then
        printf '%b%-30s mounted%b\n' "$GREEN" "$m" "$RST"
    else
        printf '%b%-30s NOT mounted%b\n' "$RED" "$m" "$RST"
        down+=("$m")
    fi
done

# Status-aware alerting: alert once when mounts go down, recover once when
# they come back. Prevents repeated emails on every cron cycle.
current_status=$(get_status)

if (( ${#down[@]} > 0 )); then
    log_to "$EXECUTION_LOG" "RESULT ${#down[@]} unmounted: ${down[*]}"

    if [[ "$current_status" != "ALERT" ]]; then
        (( DRY_RUN )) || set_status ALERT
        alert "${down[*]}"
    else
        log_to "$EXECUTION_LOG" "Already in ALERT state"
    fi
else
    log_to "$EXECUTION_LOG" "RESULT all mounted"

    if [[ "$current_status" == "ALERT" ]]; then
        (( DRY_RUN )) || set_status OK
        send_recovery_mail
    fi
fi

log_to "$EXECUTION_LOG" "END"