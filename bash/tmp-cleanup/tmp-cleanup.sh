#!/usr/bin/env bash

######################################################################################################
# tmp-cleanup.sh                                                                                     #
# Bash script that removes files older than a given age from a temp directory and prunes empty dirs. #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited, on removal errors).      #
# Author: Filcu Alexandru                                                                            #
######################################################################################################

set -euo pipefail

readonly VERSION="0.1"

######################################################
# Script directory.                                  #
#   - Auto-detected.                                 #
#   - Used as default base for state files and logs. #
#   - Override if needed.                            #
######################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

##########################################################################
# Cleanup configuration.                                                 #
#   - TMP_DIR  : directory to clean. Must exist.                         #
#   - AGE_DAYS : delete files not modified in more than this many days.  #
#                Default 7. Set to 1 to delete files older than 24 h.    #
##########################################################################

TMP_DIR="/tmp"
AGE_DAYS="7"

#######################################################################
# E-Mail alert configuration.                                         #
#   - ALERT_EMAIL : one or more recipients, space-separated.          #
#                   Leave empty to disable email alerts.              #
#   - Can also be set via the ALERT_EMAIL environment variable.       #
#   - Example (single):   ALERT_EMAIL="ops@example.com"               #
#   - Example (multiple): ALERT_EMAIL="ops@ex.com dev@ex.com"         #
#                                                                     #
#   - EMAIL_INTERVAL : seconds between emails (default 3600).         #
#                      Console alerts are always shown.               #
#   - STATE_FILE     : where the last-email timestamp is kept.        #
#######################################################################

ALERT_EMAIL="${ALERT_EMAIL:-}"
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/tmp-cleanup.email.state"

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
ERROR_LOG="${LOG_DIR}/tmp-cleanup-error.log"
EXECUTION_LOG="${LOG_DIR}/tmp-cleanup-execution.log"
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
#   - Toggle with: ./tmp-cleanup.sh --maintenance              #
#   - State is stored in MAINTENANCE_FILE (auto-managed).      #
################################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/tmp-cleanup.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/tmp-cleanup.lock"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

###################################################################
# Hostname resolution.                                            #
#   - Returns HOSTNAME_LABEL if set (preferred for containers).   #
#   - Falls back to the shell's $HOSTNAME variable.               #
#   - Then tries the hostname(1) command.                         #
#   - Last resort: returns the literal string "unknown".          #
###################################################################

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
HOST_ID="$(resolve_hostname)"
readonly HOST_ID

#######################################################################
# Logging.                                                            #
#   - init_logs  : creates LOG_DIR and touches both log files.        #
#                  If either step fails that log is disabled with a   #
#                  warning; the script never dies on log failures.    #
#   - log_to     : appends a timestamped line to a given log file.    #
#                  Best-effort; silently ignores write errors         #
#                  (e.g. disk full). Pass the file path as $1,        #
#                  followed by the message.                           #
#######################################################################

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

log_to() {
    local file=$1; shift
    [[ -n "$file" ]] || return 0
    printf '%s %s\n' "$(date '+%F %H:%M:%S')" "$*" >> "$file" 2>/dev/null || true
}

######################################################################
# Log rotation.                                                      #
#   - rotate_one  : archives a single log file when it is older      #
#                   than LOG_RETENTION_DAYS, then deletes archived   #
#                   copies that have themselves aged past the same   #
#                   window. No-ops if logging or find(1) is          #
#                   unavailable.                                     #
#   - rotate_logs : calls rotate_one for both log files. Must run    #
#                   before init_logs so that init_logs's touch()     #
#                   does not reset file mtimes and prevent rotation. #
######################################################################

rotate_one() {
    local file=$1
    [[ -n "$file" && -f "$file" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))   || return 0
    command -v find >/dev/null 2>&1 || return 0

    local base dir
    base=$(basename "$file")
    dir=$(dirname "$file")

    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        local archive="${file}.$(date +%F_%H%M%S)"
        mv "$file" "$archive" 2>/dev/null || true
        touch "$archive" 2>/dev/null || true
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

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    touch "$LOCK_FILE" 2>/dev/null   || return 0
    exec 200>"$LOCK_FILE"
    flock -n 200 || exit 0
}

##################################################################
# E-Mail rate-limiting.                                          #
#   - should_send_email : returns 0 (true) if EMAIL_INTERVAL     #
#                         seconds have elapsed since the last    #
#                         sent email; returns 1 otherwise.       #
#                         Always allows sending if STATE_FILE    #
#                         does not exist or is unreadable.       #
#   - mark_email_sent   : writes the current epoch timestamp     #
#                         to STATE_FILE (best-effort).           #
#   - last_email_age    : returns a human-readable string like   #
#                         "3542s ago" or "never" for use in      #
#                         logs and dry-run output.               #
##################################################################

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

######################################################################
# Prerequisites check.                                               #
#   - Prints the availability of all required and optional tools,    #
#     the active configuration, and current runtime state.           #
#   - Called automatically when --dry-run is used so the operator    #
#     can verify the environment before a real run.                  #
#   - Output uses color when stdout is a terminal (OK=green,         #
#     MISSING/DISABLED=red).                                         #
######################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"

    if command -v find >/dev/null 2>&1; then
        printf '  %-28s %b\n' "find" "$ok"
    else
        printf '  %-28s %b (required)\n' "find" "$miss"
    fi
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

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Host ID:" "$HOST_ID"
    printf '  %-28s %s\n' "Directory:" "$TMP_DIR"
    printf '  %-28s %s days\n' "Max file age:" "$AGE_DAYS"
    if [[ -n "$ALERT_EMAIL" ]]; then
        printf '  %-28s %s\n' "E-Mail:" "$ALERT_EMAIL"
        printf '  %-28s %ss\n' "E-Mail interval:" "$EMAIL_INTERVAL"
    else
        printf '  %-28s %b\n' "E-Mail:" "$dis"
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

####################################################
# CLI helpers.                                     #
#   - usage : prints the help text to stdout.      #
#   - die   : prints an error to stderr and exits  #
#             with code 1.                         #
####################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Delete files older than AGE_DAYS from TMP_DIR, then prune empty subdirectories.
Email alerts are rate-limited to one every EMAIL_INTERVAL seconds (default 3600).
Console alerts are not rate-limited.

Options:
  --dry-run       Check prerequisites and preview deletions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit

Email: set ALERT_EMAIL in the script (or via environment) to enable.
       Requires a working 'mail' command and a configured MTA/relay.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

####################################################################
# Alert.                                                           #
#   - Emits a console message to stderr (always, never            #
#     rate-limited).                                              #
#   - Logs the alert to ERROR_LOG.                                 #
#   - Optionally sends an email, rate-limited to one message every #
#     EMAIL_INTERVAL seconds (default 3600).                       #
#   - Fully suppressed (console + email) while maintenance mode   #
#     is active.                                                   #
#   - In dry-run mode previews all actions without performing them.#
####################################################################

alert() {
    local detail="$*"
    local body="Temp cleanup problem on ${HOST_ID}: ${detail}"

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
        # Intentionally unquoted: ALERT_EMAIL may hold multiple space-separated recipients.
        echo "$body" | mail -s "Temp cleanup alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

# Parse CLI flags; --maintenance/--version/--help exit immediately.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)     DRY_RUN=1; shift ;;
        --maintenance) toggle_maintenance; exit 0 ;;
        --version)     echo "Version=${VERSION}"; exit 0 ;;
        --help)        usage; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
done

##########################################################################
# Main.                                                                  #
#   - Validates that find(1) is available and TMP_DIR exists.            #
#   - Acquires the lock, rotates logs, initializes logging.              #
#   - In dry-run mode, runs check_prerequisites then lists what would    #
#     be deleted without touching anything.                              #
#   - Finds all files in TMP_DIR older than AGE_DAYS, deletes them one   #
#     by one, logging each deletion. Counts removed and failed files.    #
#   - Prunes empty subdirectories after file removal.                    #
#   - Fires alert() if any file could not be deleted.                    #
##########################################################################

command -v find >/dev/null 2>&1 || die "find not found"
[[ -d "$TMP_DIR" ]] || die "directory not found: $TMP_DIR"

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}] cleaning ${TMP_DIR} (files older than ${AGE_DAYS} days)"

mapfile -t old_files < <(find "$TMP_DIR" -mindepth 1 -type f -mtime +"$AGE_DAYS" 2>/dev/null)

if (( DRY_RUN )); then
    if (( ${#old_files[@]} == 0 )); then
        echo "[dry-run] nothing older than ${AGE_DAYS} days in ${TMP_DIR}"
        log_to "$EXECUTION_LOG" "RESULT nothing to delete"
    else
        echo "[dry-run] would delete ${#old_files[@]} file(s) from ${TMP_DIR}:"
        printf '  %s\n' "${old_files[@]}"
        echo "[dry-run] would then prune empty subdirectories"
        log_to "$EXECUTION_LOG" "RESULT would delete ${#old_files[@]} file(s)"
    fi
    log_to "$EXECUTION_LOG" "END"
    exit 0
fi

removed=0
failed=0
for f in "${old_files[@]}"; do
    if rm -f -- "$f" 2>/dev/null; then
        (( ++removed )) || true
        log_to "$EXECUTION_LOG" "DELETED ${f}"
    else
        (( ++failed )) || true
        log_to "$ERROR_LOG" "FAILED to delete ${f}"
    fi
done

find "$TMP_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true

printf '%bRemoved %s file(s) older than %s days from %s; pruned empty subdirectories.%b\n' \
    "$GREEN" "$removed" "$AGE_DAYS" "$TMP_DIR" "$RST"
log_to "$EXECUTION_LOG" "RESULT removed=${removed} failed=${failed}"

if (( failed > 0 )); then
    alert "could not delete ${failed} file(s) from ${TMP_DIR} (removed ${removed} successfully)"
fi

log_to "$EXECUTION_LOG" "END"