#!/usr/bin/env bash

#####################################################################################
# raid-health-monitor.sh                                                            #
# Bash script that inspects /proc/mdstat for degraded or recovering MD RAID arrays. #
# Detects failed members ([_] in the status map) and active resync/recovery.        #
# Cleanly reports 'no arrays' on systems without software RAID.                     #
# Supports optional Checkmk and Grafana alert integration.                          #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).        #
# Author: Filcu Alexandru                                                           #
#####################################################################################

set -euo pipefail
export LC_ALL=C   # stable decimal separator regardless of locale

readonly VERSION="0.1"

###################################################################
# Script directory (auto-detected; used as default base for state #
# files and logs). Override if needed.                            #
###################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

######################################################################
# This monitor has no numeric threshold: it alerts when any MD RAID  #
# array is degraded (a member is down) or otherwise not fully clean. #
#   - ALERT_ON_RESYNC : also alert while an array is resyncing.      #
######################################################################

ALERT_ON_RESYNC=0

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
STATE_FILE="${SCRIPT_DIR}/raid-health-monitor.email.state"

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
ERROR_LOG="${LOG_DIR}/raid-health-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/raid-health-monitor-execution.log"
LOG_RETENTION_DAYS="14"

###############################################################
# Host identification.                                        #
#   - Used in alerts, emails, and logs.                       #
#   - Default: system hostname.                               #
#   - Set a custom label when running in containers where the #
#     hostname is an auto-generated ID (e.g., "app-prod-01"). #
###############################################################

HOSTNAME_LABEL=""

###########################################################
# Maintenance mode.                                       #
#   - Alerts are suppressed while maintenance is active.  #
#   - Toggle with: ./raid-health-monitor.sh --maintenance            #
#   - State is stored in MAINTENANCE_FILE (auto-managed). #
###########################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/raid-health-monitor.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/raid-health-monitor.lock"

###################################################################
# Status tracking.                                                #
#   - Prevents repeated alerts while the condition persists.      #
#   - Sends a recovery email when the condition clears.           #
#   - Possible values stored in this file: OK, ALERT.             #
###################################################################

STATUS_FILE="${SCRIPT_DIR}/raid-health-monitor.status"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

#################################################################
# Hostname resolution.                                          #
#   - Returns HOSTNAME_LABEL if set (preferred for containers). #
#   - Falls back to the shell's $HOSTNAME variable.             #
#   - Then tries the hostname(1) command.                       #
#   - Last resort: returns the literal string "unknown".        #
#################################################################

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

######################################################################
# Logging.                                                           #
#   - init_logs : creates LOG_DIR and touches both log files.        #
#   - log_to    : appends a timestamped line to a given log file.    #
######################################################################

init_logs() {
    if [[ -n "$ERROR_LOG" || -n "$EXECUTION_LOG" ]] && [[ -n "$LOG_DIR" ]]; then
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            echo "Warning: could not create log directory ${LOG_DIR}; logging disabled" >&2
            ERROR_LOG="" EXECUTION_LOG=""; return
        fi
    fi
    if [[ -n "$ERROR_LOG" ]] && ! touch "$ERROR_LOG" 2>/dev/null; then
        echo "Warning: could not write ${ERROR_LOG}; error logging disabled" >&2; ERROR_LOG=""
    fi
    if [[ -n "$EXECUTION_LOG" ]] && ! touch "$EXECUTION_LOG" 2>/dev/null; then
        echo "Warning: could not write ${EXECUTION_LOG}; execution logging disabled" >&2; EXECUTION_LOG=""
    fi
}

log_to() {
    local file=$1; shift
    [[ -n "$file" ]] || return 0
    printf '%s %s\n' "$(date '+%F %H:%M:%S')" "$*" >> "$file" 2>/dev/null || true
}

#####################################################################
# Log rotation.                                                     #
#   - rotate_one  : archives a log file older than LOG_RETENTION,   #
#                   then prunes archives past the same window.      #
#   - rotate_logs : calls rotate_one for both log files.            #
#####################################################################

rotate_one() {
    local file=$1
    [[ -n "$file" && -f "$file" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))   || return 0
    command -v find >/dev/null 2>&1 || return 0
    local base dir
    base=$(basename "$file"); dir=$(dirname "$file")
    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$file" "${file}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi
    find "$dir" -maxdepth 1 -type f -name "${base}.*" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

rotate_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    rotate_one "$ERROR_LOG"; rotate_one "$EXECUTION_LOG"
}

##################################################################
# Locking.                                                       #
#   - acquire_lock : flock -n on LOCK_FILE; exits 0 if another    #
#                    instance holds it. Skipped gracefully if     #
#                    flock is unavailable or the file cannot be   #
#                    created (container / read-only filesystem).  #
##################################################################

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    touch "$LOCK_FILE" 2>/dev/null   || return 0
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0
}

#####################################################################
# Email rate-limiting.                                              #
#   - should_send_email : true if EMAIL_INTERVAL seconds elapsed.   #
#   - mark_email_sent   : writes the current epoch timestamp.       #
#   - last_email_age    : human-readable "Ns ago" / "never".       #
#####################################################################

should_send_email() {
    [[ -r "$STATE_FILE" ]] || return 0
    local last now
    last=$(< "$STATE_FILE") || return 0
    [[ "$last" =~ ^[0-9]+$ ]] || return 0
    now=$(date +%s)
    (( now - last >= EMAIL_INTERVAL ))
}

mark_email_sent() { date +%s > "$STATE_FILE" 2>/dev/null || true; }

last_email_age() {
    [[ -r "$STATE_FILE" ]] || { echo "never"; return; }
    local last
    last=$(< "$STATE_FILE") || { echo "never"; return; }
    [[ "$last" =~ ^[0-9]+$ ]] || { echo "never"; return; }
    echo "$(( $(date +%s) - last ))s ago"
}

###################################################################
# Status tracking.                                                #
#   - get_status : reads STATUS_FILE; returns OK or ALERT.        #
#   - set_status : writes OK or ALERT (best-effort).              #
###################################################################

get_status() {
    [[ -r "$STATUS_FILE" ]] || { echo "OK"; return; }
    local s; s=$(< "$STATUS_FILE") || { echo "OK"; return; }
    case "$s" in OK|ALERT) echo "$s" ;; *) echo "OK" ;; esac
}

set_status() { echo "$1" > "$STATUS_FILE" 2>/dev/null || true; }

###################################################################
# Recovery.                                                       #
#   - send_recovery_mail : one email when the condition clears,   #
#                          not rate-limited. Skipped if           #
#                          ALERT_EMAIL is empty or mail absent.   #
###################################################################

send_recovery_mail() {
    [[ -n "$ALERT_EMAIL" ]]        || return 0
    command -v mail >/dev/null 2>&1 || return 0
    local body="RAID arrays back to healthy on ${HOST_ID}"
    if (( DRY_RUN )); then
        echo "[dry-run] would send recovery email to: ${ALERT_EMAIL}"; return 0
    fi
    # shellcheck disable=SC2086
    echo "$body" | mail -s "Recovery on ${HOST_ID}" $ALERT_EMAIL
    log_to "$ERROR_LOG" "RECOVERY EMAIL sent to ${ALERT_EMAIL}"
}

###################################################################
# Prerequisites check (shown with --dry-run).                     #
###################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"
    if [[ -r /proc/mdstat ]]; then
        printf '  %-28s %b\n' "/proc/mdstat" "$ok"
    else
        printf '  %-28s %b (software RAID not present or /proc unavailable)\n' "/proc/mdstat" "$miss"
    fi
    for bin in mdadm mail flock find; do
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-28s %b\n' "$bin" "$ok"
        else
            case "$bin" in
                mdadm) printf '  %-28s %b (detailed array info unavailable (status still read from /proc))\n' "$bin" "$miss" ;;
                mail) printf '  %-28s %b (email will not work)\n' "$bin" "$miss" ;;
                flock) printf '  %-28s %b (locking disabled)\n' "$bin" "$miss" ;;
                find) printf '  %-28s %b (log rotation disabled)\n' "$bin" "$miss" ;;
            esac
        fi
    done

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Host ID:" "$HOST_ID"
    if [[ "$(id -u 2>/dev/null)" == "0" ]]; then
        printf '  %-28s %b\n' "Privileges:" "${GREEN}root${RST}"
    else
        printf '  %-28s %b\n' "Privileges:" "${RED}non-root${RST} (some checks may be limited)"
    fi
    printf '  %-28s %s\n' "Alert on resync:" "${ALERT_ON_RESYNC}"
    if [[ -n "$ALERT_EMAIL" ]]; then
        printf '  %-28s %s\n'  "E-Mail:"          "$ALERT_EMAIL"
        printf '  %-28s %ss\n' "E-Mail interval:" "$EMAIL_INTERVAL"
    else
        printf '  %-28s %b\n' "E-Mail:" "$dis"
    fi
    [[ -n "$ERROR_LOG" ]]     && printf '  %-28s %s\n' "Error log:"     "$ERROR_LOG"     \
                               || printf '  %-28s %b\n' "Error log:"     "$dis"
    [[ -n "$EXECUTION_LOG" ]] && printf '  %-28s %s\n' "Execution log:" "$EXECUTION_LOG" \
                               || printf '  %-28s %b\n' "Execution log:" "$dis"
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
    [[ -w "$(dirname "$LOCK_FILE")" ]] \
        && printf '  %-28s %b\n' "Lock directory writable:" "$ok" \
        || printf '  %-28s %b\n' "Lock directory writable:" "$miss"
    echo
}

###################################################################
# Maintenance toggle (called by --maintenance; exits after).      #
###################################################################

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

###################################################################
# Alert.                                                          #
#   - alert_body : per-script extra context appended to emails.   #
#   - alert      : console message (always), error-log entry,     #
#                  and optional rate-limited email. Suppressed    #
#                  while maintenance is active. Dry-run previews. #
###################################################################

alert_body() {
    echo "Current /proc/mdstat:"; sed 's/^/  /' /proc/mdstat 2>/dev/null
}

alert() {
    local detail="$*"
    local extra; extra=$(alert_body)
    local body
    body="${SUMMARY} on ${HOST_ID}: ${detail}"
    [[ -n "$extra" ]] && body="${body}

${extra}"

    if [[ -f "$MAINTENANCE_FILE" ]]; then
        log_to "$EXECUTION_LOG" "Maintenance mode active; alert suppressed"
        return 0
    fi

    log_to "$ERROR_LOG" "ALERT ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        [[ -n "$extra" ]] && { echo "[dry-run] email body would include:"; echo "$extra"; }
        if [[ -n "$ALERT_EMAIL" ]]; then
            if should_send_email; then
                echo "[dry-run] would email: ${ALERT_EMAIL} (last sent: $(last_email_age))"
            else
                echo "[dry-run] would skip email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)"
            fi
        fi
        return 0
    fi

    echo "ALERT: ${SUMMARY} on ${HOST_ID}: ${detail}" >&2

    [[ -n "$ALERT_EMAIL" ]] || return 0
    if ! command -v mail >/dev/null 2>&1; then
        echo "Warning: ALERT_EMAIL is set but 'mail' command was not found" >&2; return 0
    fi

    if should_send_email; then
        # shellcheck disable=SC2086
        echo "$body" | mail -s "Alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

###################################################################
# Evaluation.                                                     #
#   - evaluate : inspects the system and sets three globals:      #
#       OVER    -> 1 when the alert condition is met, else 0      #
#       SUMMARY -> short human-readable status line               #
#       DETAIL  -> detail string passed to alert()/logs           #
###################################################################

OVER=0
SUMMARY=""
DETAIL=""

evaluate() {
    [[ -r /proc/mdstat ]] || { OVER=0; SUMMARY="/proc/mdstat unavailable"; DETAIL="no md subsystem"; return; }
    local arrays; arrays=$(grep -c '^md' /proc/mdstat 2>/dev/null || echo 0)
    if (( arrays == 0 )); then OVER=0; SUMMARY="No MD RAID arrays present"; DETAIL="0 arrays"; return; fi
    local degraded=0 resync=0
    grep -qE '\[[U_]*_[U_]*\]' /proc/mdstat 2>/dev/null && degraded=1
    grep -qiE 'resync|recovery|rebuild' /proc/mdstat 2>/dev/null && resync=1
    if (( degraded )); then
        OVER=1; SUMMARY="RAID DEGRADED (${arrays} array(s))"; DETAIL="degraded member detected"
    elif (( resync && ALERT_ON_RESYNC )); then
        OVER=1; SUMMARY="RAID resyncing (${arrays} array(s))"; DETAIL="resync/recovery in progress"
    else
        OVER=0; SUMMARY="RAID healthy (${arrays} array(s))"; DETAIL="all arrays clean"
    fi
}

################################################################
# CLI.                                                         #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Inspect software RAID arrays via /proc/mdstat and alert on degraded arrays.

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit

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

###########################################################################
# Main.                                                                   #
#   - Status-aware alerting: alert once when the condition appears, stay  #
#     silent while it persists, send a recovery email when it clears.     #
###########################################################################

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}]"

evaluate

if (( OVER )); then
    printf '%b%s%b\n' "$RED" "$SUMMARY" "$RST"
    log_to "$EXECUTION_LOG" "RESULT ${SUMMARY} (alert)"
else
    printf '%b%s%b\n' "$GREEN" "$SUMMARY" "$RST"
    log_to "$EXECUTION_LOG" "RESULT ${SUMMARY} (ok)"
fi

current_status=$(get_status)

if (( OVER )); then
    if [[ "$current_status" != "ALERT" ]]; then
        (( DRY_RUN )) || set_status ALERT
        alert "$DETAIL"
    else
        log_to "$EXECUTION_LOG" "Already in ALERT state"
        (( DRY_RUN )) && alert "$DETAIL"
    fi
else
    if [[ "$current_status" == "ALERT" ]]; then
        (( DRY_RUN )) || set_status OK
        send_recovery_mail
    fi
fi

log_to "$EXECUTION_LOG" "END"
