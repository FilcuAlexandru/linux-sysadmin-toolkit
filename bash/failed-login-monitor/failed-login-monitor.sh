#!/usr/bin/env bash

###################################################################################
# failed-login-monitor.sh                                                         #
# Bash script that counts failed SSH login attempts in a configurable time window #
# and alerts when the count exceeds a threshold (brute-force detection).          #
# Reads from journalctl (systemd) with fallback to /var/log/auth.log (syslog).    #
# Supports optional Checkmk and Grafana alert integration.                        #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).      #
# Author: Filcu Alexandru                                                         #
###################################################################################

set -euo pipefail

readonly VERSION="0.1"

###################################################################
# Script directory (auto-detected; used as default base for state #
# files and logs). Override if needed.                            #
###################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###################################################################
# Detection configuration.                                        #
#   - WINDOW_MINUTES : look back this many minutes when counting  #
#                      failed attempts. Default: 60 (one hour).   #
#   - THRESHOLD      : alert when the failed attempt count in the #
#                      window exceeds this value. Default: 10.    #
#   - AUTH_LOG       : fallback log file when journalctl is not   #
#                      available. Default: /var/log/auth.log.     #
#                      Set to empty to disable the fallback.      #
###################################################################

WINDOW_MINUTES="60"
THRESHOLD="10"
AUTH_LOG="/var/log/auth.log"

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
STATE_FILE="${SCRIPT_DIR}/failed-login-monitor.email.state"

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
ERROR_LOG="${LOG_DIR}/failed-login-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/failed-login-monitor-execution.log"
LOG_RETENTION_DAYS="14"

###############################################################
# Host identification.                                        #
#   - Used in alerts, emails, and logs.                       #
#   - Default: system hostname.                               #
#   - Set a custom label when running in containers where the #
#     hostname is an auto-generated ID (e.g., "app-prod-01"). #
###############################################################

HOSTNAME_LABEL=""

############################################################
# Maintenance mode.                                        #
#   - Alerts are suppressed while maintenance is active.   #
#   - Toggle with: ./failed-login-monitor.sh --maintenance #
#   - State is stored in MAINTENANCE_FILE (auto-managed).  #
############################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/failed-login-monitor.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/failed-login-monitor.lock"

#########################################################################
# Status tracking.                                                      #
#   - Prevents repeated alerts while the count stays above threshold.   #
#   - Sends a recovery email when the count drops back below threshold. #
#   - Possible values stored in this file: OK, ALERT.                   #
#########################################################################

STATUS_FILE="${SCRIPT_DIR}/failed-login-monitor.status"

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
#                 If either step fails that log is disabled with a   #
#                 warning; the script never dies on log failures.    #
#   - log_to    : appends a timestamped line to a given log file.    #
#                 Best-effort; silently ignores write errors.        #
#                 Pass the file path as $1, followed by the message. #
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
        echo "Warning: could not write ${EXECUTION_LOG}; execution logging disabled" >&2
        EXECUTION_LOG=""
    fi
}

log_to() {
    local file=$1; shift
    [[ -n "$file" ]] || return 0
    printf '%s %s\n' "$(date '+%F %H:%M:%S')" "$*" >> "$file" 2>/dev/null || true
}

#####################################################################
# Log rotation.                                                     #
#   - rotate_one  : archives a single log file when it is older     #
#                   than LOG_RETENTION_DAYS, then deletes archived  #
#                   copies past the same window. Skipped if find(1) #
#                   is unavailable (e.g., minimal containers).      #
#   - rotate_logs : calls rotate_one for both log files.            #
#####################################################################

rotate_one() {
    local file=$1
    [[ -n "$file" && -f "$file" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))   || return 0
    command -v find >/dev/null 2>&1 || return 0
    local base dir
    base=$(basename "$file"); dir=$(dirname "$file")
    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" \
                   -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$file" "${file}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi
    find "$dir" -maxdepth 1 -type f -name "${base}.*" \
         -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

rotate_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    rotate_one "$ERROR_LOG"; rotate_one "$EXECUTION_LOG"
}

##################################################################
# Locking.                                                       #
#   - acquire_lock : opens a file descriptor on LOCK_FILE and    #
#                    calls flock -n (non-blocking). If another   #
#                    instance already holds the lock the script  #
#                    exits silently with code 0 so cron does not #
#                    report an error.                            #
#                    Skipped gracefully if flock is unavailable  #
#                    or the lock file cannot be created.         #
##################################################################

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    touch "$LOCK_FILE" 2>/dev/null   || return 0
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0
}

#####################################################################
# Email rate-limiting.                                              #
#   - should_send_email : returns 0 (true) if EMAIL_INTERVAL        #
#                         seconds have elapsed since the last sent  #
#                         email; returns 1 otherwise. Always allows #
#                         sending if STATE_FILE does not exist or   #
#                         is unreadable / corrupt.                  #
#   - mark_email_sent   : writes the current epoch timestamp to     #
#                         STATE_FILE (best-effort, never fatal).    #
#   - last_email_age    : returns a human-readable string such as   #
#                         "3542s ago" or "never" for use in         #
#                         logs and dry-run output.                  #
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
#   - get_status : reads STATUS_FILE and returns OK or ALERT.     #
#                  Returns OK when the file is missing, empty, or #
#                  contains an unrecognised value.                #
#   - set_status : writes OK or ALERT to STATUS_FILE.             #
#                  Best-effort; never fatal on write failure.     #
###################################################################

get_status() {
    [[ -r "$STATUS_FILE" ]] || { echo "OK"; return; }
    local s; s=$(< "$STATUS_FILE") || { echo "OK"; return; }
    case "$s" in OK|ALERT) echo "$s" ;; *) echo "OK" ;; esac
}

set_status() { echo "$1" > "$STATUS_FILE" 2>/dev/null || true; }

####################################################################
# Recovery.                                                        #
#   - send_recovery_mail : sends a single recovery email when the  #
#                          failed login count drops back below the #
#                          threshold. Not rate-limited. Skipped if #
#                          ALERT_EMAIL is empty or mail(1) is      #
#                          unavailable.                            #
####################################################################

send_recovery_mail() {
    [[ -n "$ALERT_EMAIL" ]]        || return 0
    command -v mail >/dev/null 2>&1 || return 0
    local body="Failed SSH logins on ${HOST_ID} are back below threshold (${THRESHOLD} in ${WINDOW_MINUTES}min)"
    if (( DRY_RUN )); then
        echo "[dry-run] would send recovery email to: ${ALERT_EMAIL}"; return 0
    fi
    # shellcheck disable=SC2086
    echo "$body" | mail -s "Failed login recovery on ${HOST_ID}" $ALERT_EMAIL
    log_to "$ERROR_LOG" "RECOVERY EMAIL sent to ${ALERT_EMAIL}"
}

###################################################################
# Prerequisites check.                                            #
#   - Prints the availability of all required and optional tools, #
#     the active configuration, and the current runtime state.    #
#   - Called automatically when --dry-run is used so the operator #
#     can verify the environment before a real run.               #
#   - Output uses color when stdout is a terminal (OK=green,      #
#     MISSING/DISABLED=red).                                      #
###################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"
    if command -v journalctl >/dev/null 2>&1; then
        printf '  %-28s %b\n' "journalctl (primary)" "$ok"
    else
        printf '  %-28s %b\n' "journalctl" "$miss"
        if [[ -n "$AUTH_LOG" && -r "$AUTH_LOG" ]]; then
            printf '  %-28s %b\n' "auth.log (fallback)" "$ok"
        elif [[ -n "$AUTH_LOG" ]]; then
            printf '  %-28s %b (not readable: %s)\n' "auth.log" "$miss" "$AUTH_LOG"
        else
            printf '  %-28s %b\n' "auth.log" "$dis"
        fi
    fi
    for bin in mail flock find; do
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-28s %b\n' "$bin" "$ok"
        else
            case "$bin" in
                mail)  printf '  %-28s %b (email will not work)\n' "$bin" "$miss" ;;
                flock) printf '  %-28s %b (locking disabled)\n' "$bin" "$miss" ;;
                find)  printf '  %-28s %b (log rotation disabled)\n' "$bin" "$miss" ;;
            esac
        fi
    done

    echo
    echo "Configuration:"
    printf '  %-28s %s\n'   "Host ID:"       "$HOST_ID"
    printf '  %-28s %s min\n' "Window:"      "$WINDOW_MINUTES"
    printf '  %-28s %s\n'   "Threshold:"     "$THRESHOLD"
    if [[ -n "$AUTH_LOG" ]]; then
        printf '  %-28s %s\n' "Auth log fallback:" "$AUTH_LOG"
    else
        printf '  %-28s %b\n' "Auth log fallback:" "$dis"
    fi
    if [[ -n "$ALERT_EMAIL" ]]; then
        printf '  %-28s %s\n'  "E-Mail:"          "$ALERT_EMAIL"
        printf '  %-28s %ss\n' "E-Mail interval:" "$EMAIL_INTERVAL"
    else
        printf '  %-28s %b\n' "E-Mail:" "$dis"
    fi
    [[ -n "$ERROR_LOG" ]]     && printf '  %-28s %s\n' "Error log:"     "$ERROR_LOG" \
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
# Maintenance toggle.                                             #
#   - Called by --maintenance; exits immediately after toggling.  #
#   - If MAINTENANCE_FILE exists: removes it (maintenance off).   #
#   - If MAINTENANCE_FILE is absent: creates it (maintenance on). #
#   - Dies if the marker file cannot be created.                  #
###################################################################

toggle_maintenance() {
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        rm -f "$MAINTENANCE_FILE"
        echo "Maintenance mode disabled"
        log_to "$EXECUTION_LOG" "Maintenance mode disabled by user"
    else
        touch "$MAINTENANCE_FILE" 2>/dev/null \
            || die "could not create ${MAINTENANCE_FILE}"
        echo "Maintenance mode enabled"
        log_to "$EXECUTION_LOG" "Maintenance mode enabled by user"
    fi
}

#####################################################################
# Alert.                                                            #
#   - alert : emits a console message to stderr (always, never      #
#             rate-limited), logs the alert to ERROR_LOG, and       #
#             optionally sends an email rate-limited to one message #
#             every EMAIL_INTERVAL seconds (default 3600).          #
#             Fully suppressed while maintenance is active.         #
#             In dry-run mode previews all actions without firing.  #
#####################################################################

alert() {
    local detail="$*"
    local body="High SSH failure rate on ${HOST_ID}: ${detail}"

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
        echo "$body" | mail -s "Failed login alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

######################################################################
# Failed login counting.                                             #
#   - count_failed_logins : counts failed SSH login attempts in the  #
#                           last WINDOW_MINUTES minutes.             #
#   - Source priority: journalctl (systemd) -> AUTH_LOG (syslog).    #
#   - journalctl: filters by _COMM=sshd and 'Failed' keyword.        #
#   - auth.log: greps for 'Failed password' within the time window   #
#               using awk to filter by parsed timestamp.             #
#   - Returns the count as a plain integer on stdout.                #
#   - Returns 0 if neither source is available (safe default).       #
#   - top_offenders : extracts the top 5 source IPs with the most    #
#                     failed attempts for inclusion in alert emails. #
######################################################################

count_failed_logins() {
    local since
    since=$(date --date="${WINDOW_MINUTES} minutes ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || {
        # Fallback for BSD date (macOS)
        since=$(date -v "-${WINDOW_MINUTES}M" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || since=""
    }

    # Primary: journalctl
    if command -v journalctl >/dev/null 2>&1; then
        if [[ -n "$since" ]]; then
            journalctl _COMM=sshd --since="$since" --no-pager -q 2>/dev/null \
                | grep -c "Failed\|Invalid\|authentication failure" 2>/dev/null \
                || echo 0
        else
            journalctl _COMM=sshd --no-pager -q 2>/dev/null \
                | grep -c "Failed\|Invalid\|authentication failure" 2>/dev/null \
                || echo 0
        fi
        return
    fi

    # Fallback: auth.log
    if [[ -n "$AUTH_LOG" && -r "$AUTH_LOG" ]]; then
        local cutoff_epoch
        cutoff_epoch=$(date --date="${WINDOW_MINUTES} minutes ago" '+%s' 2>/dev/null) || cutoff_epoch=0
        awk -v cutoff="$cutoff_epoch" '
            /Failed password|Invalid user|authentication failure/ {
                # Parse syslog timestamp: "Mon DD HH:MM:SS"
                months = "JanFebMarAprMayJunJulAugSepOctNovDec"
                m = (index(months, $1) + 2) / 3
                d = $2
                split($3, t, ":")
                cmd = "date -d \"" $1 " " $2 " " $3 "\" +%s 2>/dev/null"
                cmd | getline ts; close(cmd)
                if (ts != "" && ts+0 >= cutoff+0) count++
            }
            END { print count+0 }
        ' "$AUTH_LOG"
        return
    fi

    echo 0
}

top_offenders() {
    local since
    since=$(date --date="${WINDOW_MINUTES} minutes ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) \
        || since=""

    local raw=""

    if command -v journalctl >/dev/null 2>&1; then
        if [[ -n "$since" ]]; then
            raw=$(journalctl _COMM=sshd --since="$since" --no-pager -q 2>/dev/null \
                  | grep "Failed\|Invalid" || true)
        else
            raw=$(journalctl _COMM=sshd --no-pager -q 2>/dev/null \
                  | grep "Failed\|Invalid" || true)
        fi
    elif [[ -n "$AUTH_LOG" && -r "$AUTH_LOG" ]]; then
        raw=$(grep "Failed password\|Invalid user" "$AUTH_LOG" 2>/dev/null | tail -1000 || true)
    fi

    [[ -z "$raw" ]] && return

    # Extract source IPs and count occurrences
    echo "$raw" \
        | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | awk '{print $2}' \
        | sort | uniq -c | sort -rn \
        | head -5 \
        | awk '{printf "  %5d  %s\n", $1, $2}'
}

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Count failed SSH login attempts in the last WINDOW_MINUTES minutes and alert
when the count exceeds THRESHOLD. Reads from journalctl (systemd) with
fallback to AUTH_LOG (/var/log/auth.log on syslog systems).
Sends a recovery email when the count drops back below threshold.
Email alerts are rate-limited to one every EMAIL_INTERVAL seconds (default 3600).

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

#########################################################################
# Main.                                                                 #
#   - Counts failed SSH login attempts in the last WINDOW_MINUTES.      #
#   - Prints the count with color coding (red = above threshold).       #
#   - Status-aware alerting: alerts once when count exceeds threshold,  #
#     stays silent while it remains above, recovers once it drops back. #
#   - Alert email includes the top offending source IPs.                #
#########################################################################

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" \
    "START [${HOST_ID}] window=${WINDOW_MINUTES}min threshold=${THRESHOLD}"

count=$(count_failed_logins)
[[ "$count" =~ ^[0-9]+$ ]] || count=0

current_status=$(get_status)

if (( count > THRESHOLD )); then
    printf '%bFailed SSH logins: %d in last %d min (threshold: %d)%b\n' \
        "$RED" "$count" "$WINDOW_MINUTES" "$THRESHOLD" "$RST"
    log_to "$EXECUTION_LOG" \
        "RESULT count=${count} threshold=${THRESHOLD} window=${WINDOW_MINUTES}min (above)"

    if [[ "$current_status" != "ALERT" ]]; then
        (( DRY_RUN )) || set_status ALERT
        # Build alert detail with top offenders
        offenders=$(top_offenders)
        detail="${count} failed attempts in last ${WINDOW_MINUTES}min (threshold: ${THRESHOLD})"
        if [[ -n "$offenders" ]]; then
            detail="${detail}
Top source IPs:
${offenders}"
        fi
        alert "$detail"
    else
        log_to "$EXECUTION_LOG" "Already in ALERT state"
    fi
else
    printf '%bFailed SSH logins: %d in last %d min (threshold: %d)%b\n' \
        "$GREEN" "$count" "$WINDOW_MINUTES" "$THRESHOLD" "$RST"
    log_to "$EXECUTION_LOG" \
        "RESULT count=${count} threshold=${THRESHOLD} window=${WINDOW_MINUTES}min (ok)"

    if [[ "$current_status" == "ALERT" ]]; then
        (( DRY_RUN )) || set_status OK
        send_recovery_mail
    fi
fi

log_to "$EXECUTION_LOG" "END"