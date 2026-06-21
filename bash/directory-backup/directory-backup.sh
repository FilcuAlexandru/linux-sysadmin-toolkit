#!/usr/bin/env bash

#################################################################################################
# directory-backup.sh                                                                           #
# Bash script that creates a timestamped .tar.gz backup of a directory and prunes old archives. #
# Supports optional Checkmk and Grafana alert integration.                                      #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).                    #
# Author: Filcu Alexandru                                                                       #
#################################################################################################

set -euo pipefail

readonly VERSION="0.1"

###################################################################
# Script directory (auto-detected; used as default base for state #
# files and logs). Override if needed.                            #
###################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###################################################################
# Backup configuration.                                           #
#   - SOURCE         : directory to back up.                      #
#   - BACKUP_DIR     : where archives are stored.                 #
#   - RETENTION_DAYS : delete archives older than this many days. #
###################################################################

SOURCE="/path/to/directory"
BACKUP_DIR="/var/backups"
RETENTION_DAYS="7"

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
STATE_FILE="${SCRIPT_DIR}/directory-backup.email.state"

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
ERROR_LOG="${LOG_DIR}/directory-backup-error.log"
EXECUTION_LOG="${LOG_DIR}/directory-backup-execution.log"
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
#   - Toggle with: ./directory-backup.sh --maintenance    #
#   - State is stored in MAINTENANCE_FILE (auto-managed). #
###########################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/directory-backup.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/directory-backup.lock"

######################################################################
# Status tracking.                                                   #
#   - Prevents repeated alerts while backups keep failing.           #
#   - Sends a recovery email when a backup succeeds after a failure. #
#   - Possible values stored in this file: OK, ALERT.                #
######################################################################

STATUS_FILE="${SCRIPT_DIR}/directory-backup.status"

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

#####################################################################
# Recovery.                                                         #
#   - send_recovery_mail : sends a single recovery email when a     #
#                          backup succeeds after a previous failure #
#                          (status was ALERT). Not rate-limited.    #
#                          Skipped if ALERT_EMAIL is empty or       #
#                          mail(1) is unavailable.                  #
#####################################################################

send_recovery_mail() {
    [[ -n "$ALERT_EMAIL" ]]        || return 0
    command -v mail >/dev/null 2>&1 || return 0
    local body="Backup of ${SOURCE} succeeded again on ${HOST_ID}"
    if (( DRY_RUN )); then
        echo "[dry-run] would send recovery email to: ${ALERT_EMAIL}"; return 0
    fi
    # shellcheck disable=SC2086
    echo "$body" | mail -s "Backup recovery on ${HOST_ID}" $ALERT_EMAIL
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
    for bin in tar find du mail flock; do
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-28s %b\n' "$bin" "$ok"
        else
            case "$bin" in
                tar)   printf '  %-28s %b (required)\n' "$bin" "$miss" ;;
                find)  printf '  %-28s %b (needed for retention pruning and log rotation)\n' "$bin" "$miss" ;;
                du)    printf '  %-28s %b (archive size will not be shown)\n' "$bin" "$miss" ;;
                mail)  printf '  %-28s %b (email will not work)\n' "$bin" "$miss" ;;
                flock) printf '  %-28s %b (locking disabled)\n' "$bin" "$miss" ;;
            esac
        fi
    done

    echo
    echo "Configuration:"
    printf '  %-28s %s\n'  "Host ID:"        "$HOST_ID"
    printf '  %-28s %s\n'  "Source:"         "$SOURCE"
    printf '  %-28s %s\n'  "Backup dir:"     "$BACKUP_DIR"
    printf '  %-28s %s days\n' "Retention:"  "$RETENTION_DAYS"
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
        touch "$MAINTENANCE_FILE" 2>/dev/null || die "could not create ${MAINTENANCE_FILE}"
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
    local body="Backup failed on ${HOST_ID}: ${detail}"

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
        echo "Warning: ALERT_EMAIL is set but 'mail' command was not found" >&2; return 0
    fi

    if should_send_email; then
        # shellcheck disable=SC2086
        echo "$body" | mail -s "Backup alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Create a timestamped .tar.gz backup of SOURCE in BACKUP_DIR and prune old archives.
Sends a recovery email when a backup succeeds after a previous failure.
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

#############################################################################
# Main.                                                                     #
#   - Sanity-checks prerequisites (tar, source directory).                  #
#   - Builds a timestamped archive name.                                    #
#   - In dry-run: shows what would be created and pruned, then exits.       #
#   - Creates the archive; alerts on failure.                               #
#   - Prunes archives older than RETENTION_DAYS.                            #
#   - Status-aware: alerts once on first failure, recovers once on success. #
#############################################################################

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}] source=${SOURCE}"

# Sanity checks.
command -v tar >/dev/null 2>&1 || die "tar not found"
[[ -d "$SOURCE" ]] || {
    current_status=$(get_status)
    log_to "$EXECUTION_LOG" "RESULT source not found: ${SOURCE}"
    if [[ "$current_status" != "ALERT" ]]; then
        set_status ALERT
        alert "source directory not found: ${SOURCE}"
    else
        log_to "$EXECUTION_LOG" "Already in ALERT state"
    fi
    die "source directory not found: $SOURCE"
}

# Build the timestamped archive name (date + time prevents collisions on same-day runs).
timestamp=$(date +%F_%H%M%S)
archive="${BACKUP_DIR}/backup_${timestamp}.tar.gz"

# Dry-run: preview the archive and the retention cleanup, then stop.
if (( DRY_RUN )); then
    echo "[dry-run] would archive '${SOURCE}' -> ${archive}"
    old=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' \
          -mtime +"$RETENTION_DAYS" 2>/dev/null || true)
    if [[ -n "$old" ]]; then
        echo "[dry-run] would delete archives older than ${RETENTION_DAYS} days:"
        echo "$old"
    else
        echo "[dry-run] no archives to prune"
    fi
    exit 0
fi

# Make sure the destination exists.
mkdir -p "$BACKUP_DIR" || die "cannot create backup directory: $BACKUP_DIR"

# Create the archive; on failure alert and update status.
current_status=$(get_status)

if ! tar -czf "$archive" "$SOURCE" 2>/dev/null; then
    log_to "$EXECUTION_LOG" "RESULT backup failed: ${SOURCE}"
    if [[ "$current_status" != "ALERT" ]]; then
        set_status ALERT
        alert "tar failed while backing up ${SOURCE}"
    else
        log_to "$EXECUTION_LOG" "Already in ALERT state"
    fi
    die "backup failed"
fi

# Backup succeeded.
size=$(du -h "$archive" 2>/dev/null | cut -f1)
printf '%bBackup created:%b %s (%s)\n' "$GREEN" "$RST" "$archive" "$size"
log_to "$EXECUTION_LOG" "RESULT backup created: ${archive} (${size})"

# Recovery: notify if previous run had failed.
if [[ "$current_status" == "ALERT" ]]; then
    set_status OK
    send_recovery_mail
else
    set_status OK
fi

# Retention: remove our own archives older than RETENTION_DAYS.
removed=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'backup_*.tar.gz' \
          -mtime +"$RETENTION_DAYS" -print -delete 2>/dev/null || true)
if [[ -n "$removed" ]]; then
    echo "Removed archives older than ${RETENTION_DAYS} days:"
    echo "$removed"
    log_to "$EXECUTION_LOG" "PRUNED $(echo "$removed" | wc -l) archive(s)"
fi

log_to "$EXECUTION_LOG" "END"