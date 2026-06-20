#!/usr/bin/env bash

##########################################################################################
# file-change-monitor.sh                                                                 #
# Bash script that watches a directory and reports create / modify / delete events live. #
# Runs continuously as a daemon; designed to run under systemd.                          #
# Can install itself as a systemd service (--install-service).                           #
# Supports optional Checkmk and Grafana alert integration.                               #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).             #
# Author: Filcu Alexandru                                                                #
##########################################################################################

set -euo pipefail

readonly VERSION="0.1"

###################################################################
# Script directory (auto-detected; used as default base for state #
# files and logs). Override if needed.                            #
###################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################################################
# Watch configuration.                                                     #
#   - WATCH_DIR    : directory to monitor for changes.                     #
#   - EVENTS       : inotify events to react to.                           #
#                    Supported: create modify delete moved_to moved_from   #
#   - ALERT_EVENTS : subset of EVENTS that trigger an email alert.         #
#                    Defaults to delete only. Add create/modify if needed. #
#   - SERVICE_PATH : where --install-service writes the unit file.         #
############################################################################

WATCH_DIR="/path/to/directory"
EVENTS=("create" "modify" "delete")
ALERT_EVENTS=("delete")
SERVICE_PATH="/etc/systemd/system/file-change-monitor.service"

#########################################################################
# E-Mail alert configuration.                                           #
#   - ALERT_EMAIL : one or more recipients, space-separated.            #
#                   Leave empty to disable email alerts.                #
#   - Example (single):   ALERT_EMAIL="ops@example.com"                 #
#   - Example (multiple): ALERT_EMAIL="ops@ex.com dev@ex.com"           #
#                                                                       #
#   - EMAIL_INTERVAL : minimum seconds between emails (default 3600).   #
#                      Prevents flooding when many events fire rapidly. #
#                      Console output is never rate-limited.            #
#   - STATE_FILE     : where the last-email timestamp is kept.          #
#########################################################################

ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/file-change-monitor.email.state"

######################################################################
# Logging (optional).                                                #
#   - Logs go under LOG_DIR (default: SCRIPT_DIR/logs/).             #
#   - Set to empty ("") to disable a log.                            #
#                                                                    #
#   - LOG_RETENTION_DAYS : rotate and delete logs older than this.   #
#                          Default 14 (two weeks). Set to 0 to keep  #
#                          logs forever (no rotation).               #
#   - Note: as a daemon, log rotation only happens at startup.       #
#           For continuous rotation use logrotate with copytruncate. #
######################################################################

LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/file-change-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/file-change-monitor-execution.log"
LOG_RETENTION_DAYS="14"

###############################################################
# Host identification.                                        #
#   - Used in alerts, emails, and logs.                       #
#   - Default: system hostname.                               #
#   - Set a custom label when running in containers where the #
#     hostname is an auto-generated ID (e.g., "app-prod-01"). #
###############################################################

HOSTNAME_LABEL=""

####################################################################
# Maintenance mode.                                                #
#   - Email alerts are suppressed while maintenance is active.     #
#   - Console output continues; only email delivery is suppressed. #
#   - Toggle with: ./file-change-monitor.sh --maintenance          #
#   - State is stored in MAINTENANCE_FILE (auto-managed).          #
####################################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/file-change-monitor.maintenance"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal: green=create, yellow=modify, red=delete.
if [[ -t 1 ]]; then
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RST=$'\e[0m'
else
    GREEN=""; YELLOW=""; RED=""; RST=""
fi

LOCK_FILE="${SCRIPT_DIR}/file-change-monitor.lock"

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

#######################################################################
# Logging.                                                            #
#   - init_logs  : creates LOG_DIR and touches both log files.        #
#                  If either step fails that log is disabled with a   #
#                  warning; the script never dies on log failures.    #
#   - log_to     : appends a timestamped line to a given log file.    #
#                  Best-effort; silently ignores write errors.        #
#                  Pass the file path as $1, followed by the message. #
#######################################################################

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
#                   is unavailable.                                 #
#   - rotate_logs : calls rotate_one for both log files.            #
#   - Called once at startup; as a long-running daemon the script   #
#     does not rotate logs mid-run.                                 #
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

####################################################################
# Locking (single-instance guard).                                 #
#   - acquire_lock : unlike one-shot scripts, a daemon must not    #
#                    silently exit if another instance is running. #
#                    This prints a clear error and dies so systemd #
#                    can handle the restart policy.                #
#                    Skipped gracefully if flock is unavailable.   #
####################################################################

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    touch "$LOCK_FILE" 2>/dev/null   || return 0
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        die "another instance is already running (lock: ${LOCK_FILE})"
    fi
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

#######################################################################
# Maintenance toggle.                                                 #
#   - Called by --maintenance; exits immediately after toggling.      #
#   - If MAINTENANCE_FILE exists: removes it (maintenance off).       #
#   - If MAINTENANCE_FILE is absent: creates it (maintenance on).     #
#   - While active: console output continues but email is suppressed. #
#   - Dies if the marker file cannot be created.                      #
#######################################################################

toggle_maintenance() {
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        rm -f "$MAINTENANCE_FILE"
        echo "Maintenance mode disabled (email alerts will resume)"
        log_to "$EXECUTION_LOG" "Maintenance mode disabled by user"
    else
        touch "$MAINTENANCE_FILE" 2>/dev/null || die "could not create ${MAINTENANCE_FILE}"
        echo "Maintenance mode enabled (email alerts suppressed; console output continues)"
        log_to "$EXECUTION_LOG" "Maintenance mode enabled by user"
    fi
}

###################################################################
# Prerequisites check.                                            #
#   - Prints the availability of all required and optional tools, #
#     the active configuration, and the current runtime state.    #
#   - Called automatically when --dry-run is used so the operator #
#     can verify the environment before starting the daemon.      #
#   - Output uses color when stdout is a terminal (OK=green,      #
#     MISSING/DISABLED=red).                                      #
###################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"
    if command -v inotifywait >/dev/null 2>&1; then
        printf '  %-28s %b\n' "inotifywait" "$ok"
    else
        printf '  %-28s %b (required; install inotify-tools)\n' "inotifywait" "$miss"
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
    printf '  %-28s %s\n' "Host ID:"       "$HOST_ID"
    printf '  %-28s %s\n' "Watch dir:"     "$WATCH_DIR"
    printf '  %-28s %s\n' "Events:"        "${EVENTS[*]}"
    printf '  %-28s %s\n' "Alert events:"  "${ALERT_EVENTS[*]}"
    printf '  %-28s %s\n' "Service path:"  "$SERVICE_PATH"
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
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        printf '  %-28s %b\n' "Maintenance mode:" "${RED}ACTIVE (email suppressed)${RST}"
    else
        printf '  %-28s %s\n' "Maintenance mode:" "off"
    fi
    printf '  %-28s %s\n' "Last email:" "$(last_email_age)"
    if [[ -d "$WATCH_DIR" ]]; then
        printf '  %-28s %b\n' "Watch dir exists:" "$ok"
    else
        printf '  %-28s %b\n' "Watch dir exists:" "${RED}NOT FOUND${RST}"
    fi
    echo
}

####################################################################
# Systemd unit generation.                                         #
#   - unit_file       : prints a ready-to-use systemd service unit #
#                       to stdout, embedding the real script path  #
#                       (via readlink -f) and current WATCH_DIR /  #
#                       ALERT_EMAIL values as Environment= lines.  #
#   - install_service : writes unit_file output to SERVICE_PATH,   #
#                       then calls systemctl daemon-reload.        #
#                       Writing to SERVICE_PATH is the permission  #
#                       check; on failure prints a sudo hint.      #
####################################################################

unit_file() {
    local self
    self=$(readlink -f -- "$0")
    cat <<UNIT
# Generated by ${0##*/} ${VERSION}
[Unit]
Description=File change monitor (inotify) for ${WATCH_DIR}
After=local-fs.target

[Service]
Type=simple
Environment=WATCH_DIR=${WATCH_DIR}
UNIT
    [[ -n "$ALERT_EMAIL" ]] && echo "Environment=ALERT_EMAIL=${ALERT_EMAIL}"
    cat <<UNIT
ExecStart=${self}
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
}

# Write the unit to SERVICE_PATH and reload systemd.
# Writing is the permission check: if it fails, point the user at sudo / --print-unit.
install_service() {
    if ! unit_file > "$SERVICE_PATH" 2>/dev/null; then
        die "could not write ${SERVICE_PATH} (try sudo, or: ${0##*/} --print-unit | sudo tee ${SERVICE_PATH})"
    fi
    echo "Installed: ${SERVICE_PATH}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    echo "Enable and start it with: systemctl enable --now ${SERVICE_PATH##*/}"
}

######################################################################
# Alert.                                                             #
#   - alert : emits a console message (always, never rate-limited),  #
#             logs the event to ERROR_LOG, and optionally sends an   #
#             email rate-limited to one message every EMAIL_INTERVAL #
#             seconds (default 3600).                                #
#             Email is suppressed while maintenance mode is active.  #
#             Console output continues regardless of maintenance.    #
#             In dry-run mode previews all actions without firing.   #
######################################################################

alert() {
    local detail="$*"
    local body="File event on ${HOST_ID}: ${detail}"

    log_to "$ERROR_LOG" "ALERT ${detail}"

    if (( DRY_RUN )); then
        echo "[dry-run] would raise alert: ${detail}"
        if [[ -n "$ALERT_EMAIL" ]]; then
            if [[ -f "$MAINTENANCE_FILE" ]]; then
                echo "[dry-run] would skip email (maintenance mode active)"
            elif should_send_email; then
                echo "[dry-run] would email: ${ALERT_EMAIL} (last sent: $(last_email_age))"
            else
                echo "[dry-run] would skip email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)"
            fi
        fi
        return 0
    fi

    echo "ALERT: ${body}" >&2

    [[ -n "$ALERT_EMAIL" ]] || return 0

    # Maintenance suppresses email only; console alert above always fires.
    if [[ -f "$MAINTENANCE_FILE" ]]; then
        log_to "$EXECUTION_LOG" "Email suppressed (maintenance mode active)"
        return 0
    fi

    if ! command -v mail >/dev/null 2>&1; then
        echo "Warning: ALERT_EMAIL is set but 'mail' command was not found" >&2; return 0
    fi

    if should_send_email; then
        # shellcheck disable=SC2086
        echo "$body" | mail -s "File alert on ${HOST_ID}" $ALERT_EMAIL
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
Usage: ${0##*/} [--dry-run] [--print-unit] [--install-service] [--maintenance] [--version] [--help]

Watch WATCH_DIR and print create/modify/delete events as they happen.
Runs continuously until interrupted (Ctrl-C) or stopped by systemd.
Email alerts fire for events listed in ALERT_EVENTS (default: delete only).
Email is rate-limited to one per EMAIL_INTERVAL seconds (default 3600).
Console output is never rate-limited.

Options:
  --dry-run          Watch and print events, but preview alerts instead of sending
  --print-unit       Print the systemd unit file to stdout
  --install-service  Write the unit to SERVICE_PATH and reload systemd
  --maintenance      Toggle maintenance mode (email suppressed; console continues)
  --version          Show version and exit
  --help             Show this help and exit

Email: set ALERT_EMAIL in the script to enable (one or more recipients).
       Requires a working 'mail' command and a configured MTA/relay.
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)         DRY_RUN=1; shift ;;
        --print-unit)      unit_file; exit 0 ;;
        --install-service) install_service; exit 0 ;;
        --maintenance)     toggle_maintenance; exit 0 ;;
        --version)         echo "Version=${VERSION}"; exit 0 ;;
        --help)            usage; exit 0 ;;
        *)                 die "unknown option: $1" ;;
    esac
done

#####################################################################
# Main.                                                             #
#   - Sanity-checks prerequisites (inotifywait, WATCH_DIR, EVENTS). #
#   - Builds the -e argument list from the EVENTS array.            #
#   - Runs inotifywait -m (monitor mode) piped into a read loop.    #
#   - Each event is color-coded and printed (green/yellow/red).     #
#   - Events in ALERT_EVENTS trigger alert() (email + console).     #
#   - In dry-run mode: watches and prints, but previews alerts.     #
#####################################################################

command -v inotifywait >/dev/null 2>&1 || die "inotifywait not found (install inotify-tools)"
[[ -d "$WATCH_DIR" ]]                  || die "watch directory not found: $WATCH_DIR"
(( ${#EVENTS[@]} > 0 ))                || die "no events configured in EVENTS"

acquire_lock
rotate_logs
init_logs

(( DRY_RUN )) && check_prerequisites

log_to "$EXECUTION_LOG" "START [${HOST_ID}] watching ${WATCH_DIR} for: ${EVENTS[*]}"

# Build the -e arguments for inotifywait from the EVENTS array.
event_args=()
for e in "${EVENTS[@]}"; do event_args+=(-e "$e"); done

echo "Watching ${WATCH_DIR} for: ${EVENTS[*]} (Ctrl-C to stop)"

# Return 0 if the given event should trigger an alert.
is_alert_event() {
    local ev=$1 ae
    for ae in "${ALERT_EVENTS[@]}"; do
        [[ "${ev,,}" == *"${ae,,}"* ]] && return 0
    done
    return 1
}

# -m: keep running; -q: quiet startup; --format/--timefmt: clean, parseable lines.
inotifywait -m -q "$WATCH_DIR" "${event_args[@]}" \
        --timefmt '%F %H:%M:%S' --format '%T %e %w%f' |
while read -r day time event file; do
    case "$event" in
        *DELETE*)  color=$RED    ;;
        *CREATE*)  color=$GREEN  ;;
        *MODIFY*)  color=$YELLOW ;;
        *MOVED_*)  color=$YELLOW ;;
        *)         color=$RST    ;;
    esac

    printf '%b[%s %s] %-14s %s%b\n' "$color" "$day" "$time" "$event" "$file" "$RST"
    log_to "$EXECUTION_LOG" "EVENT ${event} ${file}"

    if is_alert_event "$event"; then
        alert "${event} ${file}"
    fi
done