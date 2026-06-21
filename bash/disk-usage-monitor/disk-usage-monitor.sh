#!/usr/bin/env bash

#####################################################################################################################
# disk-usage-monitor.sh                                                                                             #
# Bash script for monitoring filesystem disk usage and highlighting filesystems exceeding a configurable threshold. #
# Reads /proc/mounts first; falls back to df(1) if /proc/mounts is unavailable.                                     #
# Supports optional Checkmk and Grafana alert integration.                                                          #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).                                        #
# Author: Filcu Alexandru                                                                                           #
#####################################################################################################################

set -euo pipefail

readonly VERSION="0.1"

###################################################################
# Script directory (auto-detected; used as default base for state #
# files and logs). Override if needed.                            #
###################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

######################################################################
# Disk usage threshold.                                              #
#   - Alert fires when any filesystem usage exceeds this percentage. #
#   - Value is a percentage (0-100).                                 #
######################################################################

THRESHOLD=80

####################################################################################
# Filesystem exclusions.                                                           #
#   - EXCLUDE_TYPES : space-separated list of filesystem types to skip.            #
#                     Add types that are not real storage (tmpfs, devtmpfs, etc.). #
#   - EXCLUDE_MOUNT : space-separated list of mountpoint prefixes to skip.         #
#   - Example: EXCLUDE_MOUNT="/run /sys /proc /dev"                                #
####################################################################################

EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay iso9660"
EXCLUDE_MOUNT=""

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
STATE_FILE="${SCRIPT_DIR}/disk-usage-monitor.email.state"

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
ERROR_LOG="${LOG_DIR}/disk-usage-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/disk-usage-monitor-execution.log"
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
#   - Toggle with: ./disk-usage-monitor.sh --maintenance  #
#   - State is stored in MAINTENANCE_FILE (auto-managed). #
###########################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/disk-usage-monitor.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/disk-usage-monitor.lock"

######################################################################
# Status tracking (per-filesystem).                                  #
#   - Tracks which filesystems are currently in ALERT state.         #
#   - Alerts once when a filesystem first exceeds the threshold.     #
#   - Sends a recovery email when it drops back below the threshold. #
#   - State file holds a space-separated list of alert mountpoints.  #
######################################################################

STATUS_FILE="${SCRIPT_DIR}/disk-usage-monitor.status"

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

######################################################################
# Status tracking (per-filesystem).                                  #
#   - get_alerted    : reads STATUS_FILE and returns the space-      #
#                      separated list of mountpoints currently in    #
#                      ALERT state. Returns empty string when file   #
#                      is missing, empty, or unreadable.             #
#   - is_in_alert    : returns 0 if a given mountpoint is in the     #
#                      current ALERT list; 1 otherwise.              #
#   - add_alert      : adds a mountpoint to the ALERT list.          #
#   - remove_alert   : removes a mountpoint from the ALERT list.     #
#   - save_alerts    : writes the current ALERT list to STATUS_FILE. #
######################################################################

# Read the current set of alerted mountpoints from STATUS_FILE.
get_alerted() {
    [[ -r "$STATUS_FILE" ]] || { echo ""; return; }
    cat "$STATUS_FILE" 2>/dev/null || echo ""
}

# Return 0 if the given mountpoint is currently in ALERT state.
is_in_alert() {
    local mp=$1
    local alerted; alerted=$(get_alerted)
    [[ " $alerted " == *" $mp "* ]]
}

# Add a mountpoint to the ALERT set and persist it.
add_alert() {
    local mp=$1
    local alerted; alerted=$(get_alerted)
    if [[ " $alerted " != *" $mp "* ]]; then
        echo "${alerted} ${mp}" | xargs > "$STATUS_FILE" 2>/dev/null || true
    fi
}

# Remove a mountpoint from the ALERT set and persist it.
remove_alert() {
    local mp=$1
    local alerted; alerted=$(get_alerted)
    echo "$alerted" | tr ' ' '\n' | grep -v "^${mp}$" | tr '\n' ' ' | xargs \
        > "$STATUS_FILE" 2>/dev/null || true
}

######################################################################
# Recovery.                                                          #
#   - send_recovery_mail : sends a single recovery email when a      #
#                          filesystem drops back below the threshold #
#                          after being in ALERT state. Not rate-     #
#                          limited. Skipped if ALERT_EMAIL is empty  #
#                          or mail(1) is unavailable.                #
######################################################################

send_recovery_mail() {
    local mp=$1
    [[ -n "$ALERT_EMAIL" ]]        || return 0
    command -v mail >/dev/null 2>&1 || return 0

    local body="Disk usage on ${mp} is back below ${THRESHOLD}% on ${HOST_ID}"

    if (( DRY_RUN )); then
        echo "[dry-run] would send recovery email for ${mp} to: ${ALERT_EMAIL}"
        return 0
    fi

    # shellcheck disable=SC2086
    echo "$body" | mail -s "Disk recovery on ${HOST_ID}" $ALERT_EMAIL
    log_to "$ERROR_LOG" "RECOVERY EMAIL sent for ${mp} to ${ALERT_EMAIL}"
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
    for bin in df awk mail flock find; do
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-28s %b\n' "$bin" "$ok"
        else
            case "$bin" in
                df)    printf '  %-28s %b (required)\n' "$bin" "$miss" ;;
                awk)   printf '  %-28s %b (required for table parsing)\n' "$bin" "$miss" ;;
                mail)  printf '  %-28s %b (email will not work)\n' "$bin" "$miss" ;;
                flock) printf '  %-28s %b (locking disabled)\n' "$bin" "$miss" ;;
                find)  printf '  %-28s %b (log rotation disabled)\n' "$bin" "$miss" ;;
            esac
        fi
    done

    echo
    echo "Configuration:"
    printf '  %-28s %s\n'   "Host ID:"          "$HOST_ID"
    printf '  %-28s %s%%\n' "Threshold:"        "$THRESHOLD"
    printf '  %-28s %s\n'   "Exclude types:"    "${EXCLUDE_TYPES:-none}"
    printf '  %-28s %s\n'   "Exclude mounts:"   "${EXCLUDE_MOUNT:-none}"
    if [[ -n "$ALERT_EMAIL" ]]; then
        printf '  %-28s %s\n'  "E-Mail:"             "$ALERT_EMAIL"
        printf '  %-28s %ss\n' "E-Mail interval:"    "$EMAIL_INTERVAL"
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
    local alerted; alerted=$(get_alerted)
    if [[ -n "$alerted" ]]; then
        printf '  %-28s %b\n' "Currently in ALERT:" "${RED}${alerted}${RST}"
    else
        printf '  %-28s %s\n' "Currently in ALERT:" "none"
    fi
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
    local body="Disk usage above ${THRESHOLD}% on ${HOST_ID}: ${detail}"

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
        echo "$body" | mail -s "Disk alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

#############################################################
# Disk usage reading.                                       #
#   - get_disk_report : reads filesystem usage with df -h.  #
#                       Returns the raw table output.       #
#   - should_exclude  : returns 0 if a filesystem should be #
#                       skipped based on EXCLUDE_TYPES or   #
#                       EXCLUDE_MOUNT prefix matching.      #
#############################################################

# Return 0 if the given filesystem type or mountpoint should be excluded.
should_exclude() {
    local fstype=$1 mountpoint=$2

    for t in $EXCLUDE_TYPES; do
        [[ "$fstype" == "$t" ]] && return 0
    done

    for m in $EXCLUDE_MOUNT; do
        [[ "$mountpoint" == "$m"* ]] && return 0
    done

    return 1
}

# Read disk usage via df. Returns the full df -hT output.
get_disk_report() {
    df -hT 2>/dev/null || df -h 2>/dev/null
}

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Show disk usage per filesystem and highlight anything above ${THRESHOLD}%.
Sends a recovery email when a filesystem drops back below the threshold.
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

###################################################################
# Main.                                                           #
#   - Reads disk usage once via df(1).                            #
#   - Prints a color-coded table (red = above threshold).         #
#   - Per-filesystem status tracking: alerts once on breach,      #
#     stays silent while above threshold, recovers once it drops. #
#   - Sends a single aggregated email for all newly breached      #
#     filesystems and a separate recovery email for each that     #
#     has returned below the threshold.                           #
###################################################################

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}] threshold=${THRESHOLD}%"

# Read disk usage once.
report=$(get_disk_report) || die "could not run df"
[[ -n "$report" ]]        || die "df returned no output"

# Detect whether df -hT (with filesystem type column) succeeded.
# With -hT the columns are: Filesystem Type Size Used Avail Use% Mounted
# Without -T:                Filesystem      Size Used Avail Use% Mounted
has_type_col=0
if echo "$report" | awk 'NR==1{print $2}' | grep -qi 'type\|fs'; then
    has_type_col=1
fi

# Print the header untouched, then color-code each data row.
echo "$report" | awk \
    -v thr="$THRESHOLD" \
    -v red="$RED" \
    -v rst="$RST" \
    -v has_type="$has_type_col" \
    -v ex_types="$EXCLUDE_TYPES" \
    -v ex_mounts="$EXCLUDE_MOUNT" '
    function should_skip(fstype, mp,    i, n, parts) {
        n = split(ex_types, parts, " ")
        for (i=1; i<=n; i++) if (fstype == parts[i]) return 1
        n = split(ex_mounts, parts, " ")
        for (i=1; i<=n; i++) if (index(mp, parts[i]) == 1) return 1
        return 0
    }
    NR == 1 { print; next }
    {
        fstype = has_type ? $2 : ""
        mp     = $NF
        if (should_skip(fstype, mp)) next
        use = 0
        for (i = 1; i <= NF; i++) if ($i ~ /%$/) { use = $i + 0; break }
        if (use > thr) print red $0 rst; else print $0
    }'

# Collect newly breached and newly recovered filesystems.
newly_breached=()
newly_recovered=()

while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse mountpoint and usage from each data row.
    mp=$(echo "$line" | awk '{print $NF}')
    fstype=$(echo "$line" | awk -v ht="$has_type_col" '{print ht ? $2 : ""}')
    use=$(echo "$line" | awk '{
        for (i=1; i<=NF; i++) if ($i ~ /%$/) { sub(/%/,"",$i); print $i+0; exit }
    }')

    [[ -z "$mp" || -z "$use" ]] && continue
    should_exclude "$fstype" "$mp" && continue

    if (( use > THRESHOLD )); then
        if ! is_in_alert "$mp"; then
            newly_breached+=("$mp")
            (( DRY_RUN )) || add_alert "$mp"
        fi
    else
        if is_in_alert "$mp"; then
            newly_recovered+=("$mp")
            (( DRY_RUN )) || remove_alert "$mp"
        fi
    fi
done < <(echo "$report" | tail -n +2)

# Alert for all newly breached filesystems in one email.
if (( ${#newly_breached[@]} > 0 )); then
    log_to "$EXECUTION_LOG" "ALERT ${newly_breached[*]}"
    alert "${newly_breached[*]}"
fi

# Send individual recovery emails for each recovered filesystem.
for mp in "${newly_recovered[@]}"; do
    log_to "$EXECUTION_LOG" "RECOVERY ${mp}"
    send_recovery_mail "$mp"
done

if (( ${#newly_breached[@]} == 0 && ${#newly_recovered[@]} == 0 )); then
    log_to "$EXECUTION_LOG" "RESULT all filesystems within threshold"
fi

log_to "$EXECUTION_LOG" "END"