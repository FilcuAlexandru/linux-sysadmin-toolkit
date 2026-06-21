#!/usr/bin/env bash

#####################################################################################################
# cert-expiry-monitor.sh                                                                            #
# Bash script that checks one or more certificates and alerts when any are about to expire.         #
# Supports PEM files, remote TLS hosts, JKS/PKCS12 keystores, and trust stores.                     #
# Supports optional Checkmk and Grafana alert integration.                                          #
# Includes email-based alerts when ALERT_EMAIL is configured (rate-limited).                        #
# Author: Filcu Alexandru                                                                           #
#####################################################################################################

set -euo pipefail
export LC_ALL=C   # ensures date -d parses the English month names openssl prints

readonly VERSION="0.1"

######################################################
# Script directory.                                  #
#   - Auto-detected.                                 #
#   - Used as default base for state files and logs. #
#   - Override if needed.                            #
######################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###########################################################################
# Certificates to monitor.                                                #
#   Each entry is a pipe-separated descriptor:                            #
#     type|target|options                                                 #
#                                                                         #
#   Supported types:                                                      #
#     file         - PEM/DER certificate file.                            #
#                    target  : path to the file.                          #
#                    options : (unused, leave empty)                      #
#                                                                         #
#     host         - Remote TLS endpoint (uses openssl s_client).         #
#                    target  : host:port  (port defaults to 443).         #
#                    options : (unused, leave empty)                      #
#                                                                         #
#     keytool      - Java keystore (JKS or PKCS12).                       #
#                    target  : path to keystore file.                     #
#                    options : password (storepass).                      #
#                    Requires: keytool (JDK/JRE).                         #
#                                                                         #
#   Leave an entry empty ("") or comment it out to skip it.               #
#                                                                         #
#   Examples:                                                             #
#     "file|/etc/ssl/certs/my-cert.pem|"                                  #
#     "host|example.com:443|"                                             #
#     "host|internal-api.company.com:8443|"                               #
#     "keytool|/opt/app/identity.jks|changeit"                            #
#     "keytool|/opt/app/trust.jks|changeit"                               #
###########################################################################

CERTS=(
    "host|example.com:443|"
)

###########################################################################
# Alert threshold.                                                        #
#   - Alert fires when a certificate expires within this many days.       #
#   - Set to 0 to disable threshold-based suppression.                    #
###########################################################################

THRESHOLD_DAYS=30

#######################################################################
# E-Mail alert configuration.                                         #
#   - ALERT_EMAIL : one or more recipients, space-separated.          #
#                   Leave empty to disable email alerts.              #
#   - Example (single):   ALERT_EMAIL="ops@example.com"               #
#   - Example (multiple): ALERT_EMAIL="ops@ex.com dev@ex.com"         #
#                                                                     #
#   - EMAIL_INTERVAL : seconds between emails (default 3600).         #
#                      Console alerts are always shown.               #
#   - STATE_FILE     : where the last-email timestamp is kept.        #
#######################################################################

ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/cert-expiry-monitor.email.state"

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
ERROR_LOG="${LOG_DIR}/cert-expiry-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/cert-expiry-monitor-execution.log"
LOG_RETENTION_DAYS="14"

#######################################################################
# Binary paths.                                                       #
#   - Set an explicit path when the tool is not in $PATH.             #
#   - Common on enterprise Linux where JDK is in a non-standard       #
#     location (e.g. /usr/java/jdk-21/bin/keytool).                   #
#   - Leave empty to auto-detect from $PATH.                          #
#                                                                     #
#   - Example: KEYTOOL_BIN="/usr/java/jdk-21/bin/keytool"             #
#   - Example: OPENSSL_BIN="/usr/local/ssl/bin/openssl"               #
#######################################################################

KEYTOOL_BIN=""
OPENSSL_BIN=""

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
#   - Toggle with: ./cert-expiry-monitor.sh --maintenance      #
#   - State is stored in MAINTENANCE_FILE (auto-managed).      #
################################################################

MAINTENANCE_FILE="${SCRIPT_DIR}/cert-expiry-monitor.maintenance"

##################################################################
# Locking.                                                       #
#   - Prevents multiple instances from running simultaneously.   #
#   - Uses flock(1); skipped if flock is unavailable or the file #
#     cannot be created (container / read-only filesystem).      #
##################################################################

LOCK_FILE="${SCRIPT_DIR}/cert-expiry-monitor.lock"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal, keeping cron and pipe output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

##########################################################################
# Binary resolution.                                                     #
#   - resolve_bin : returns the effective path for a tool.               #
#                   If the corresponding *_BIN variable is set and the   #
#                   file is executable, that path is used directly.      #
#                   Otherwise falls back to $PATH lookup.                #
#                   Prints the resolved path to stdout; returns 1 if     #
#                   the tool cannot be found by either method.           #
##########################################################################

resolve_bin() {
    local name=$1 override=$2
    if [[ -n "$override" ]]; then
        if [[ -x "$override" ]]; then
            echo "$override"
            return 0
        else
            echo "Warning: ${name} not executable at '${override}'; falling back to PATH" >&2
        fi
    fi
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return 0
    fi
    return 1
}

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
readonly HOST_ID="$(resolve_hostname)"

#######################################################################
# Logging.                                                            #
#   - init_logs  : creates LOG_DIR and touches both log files.        #
#                  If either step fails that log is disabled with a   #
#                  warning; the script never dies on log failures.    #
#   - log_to     : appends a timestamped line to a given log file.    #
#                  Best-effort; silently ignores write errors.        #
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
#                   copies past the same window. Skipped if find(1)  #
#                   is unavailable.                                  #
#   - rotate_logs : calls rotate_one for both log files.             #
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
        mv "$file" "${file}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi

    find "$dir" -maxdepth 1 -type f -name "${base}.*" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

rotate_logs() {
    (( LOG_RETENTION_DAYS > 0 )) || return 0
    rotate_one "$ERROR_LOG"
    rotate_one "$EXECUTION_LOG"
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

###################################################################
# E-Mail rate-limiting.                                           #
#   - should_send_email : returns 0 if EMAIL_INTERVAL seconds     #
#                         have elapsed since the last email.      #
#   - mark_email_sent   : writes the current epoch to STATE_FILE. #
#   - last_email_age    : returns "Xs ago" or "never".            #
###################################################################

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
#   - Called automatically when --dry-run is used.                   #
######################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"

    echo "Prerequisites:"

    if resolve_bin openssl "$OPENSSL_BIN" >/dev/null 2>/dev/null; then
        local ossl; ossl=$(resolve_bin openssl "$OPENSSL_BIN" 2>/dev/null)
        printf '  %-28s %b (%s)\n' "openssl" "$ok" "$ossl"
    else
        printf '  %-28s %b (required for file/host checks)\n' "openssl" "$miss"
    fi
    if resolve_bin keytool "$KEYTOOL_BIN" >/dev/null 2>/dev/null; then
        local ktool; ktool=$(resolve_bin keytool "$KEYTOOL_BIN" 2>/dev/null)
        printf '  %-28s %b (%s)\n' "keytool" "$ok" "$ktool"
    else
        printf '  %-28s %b (required for keytool entries)\n' "keytool" "$miss"
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
    if command -v find >/dev/null 2>&1; then
        printf '  %-28s %b\n' "find" "$ok"
    else
        printf '  %-28s %b (log rotation disabled)\n' "find" "$miss"
    fi

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Host ID:" "$HOST_ID"
    printf '  %-28s %s days\n' "Threshold:" "$THRESHOLD_DAYS"
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
    echo "Certificates:"
    local i=1
    for entry in "${CERTS[@]}"; do
        [[ -z "$entry" ]] && { printf '  [%d] (empty, will be skipped)\n' "$i"; (( i++ )); continue; }
        local type target opts
        IFS='|' read -r type target opts <<< "$entry"
        printf '  [%d] type=%-10s target=%s\n' "$i" "$type" "$target"
        (( i++ ))
    done

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

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--maintenance] [--version] [--help]

Check one or more certificates and alert if any expire within ${THRESHOLD_DAYS} days.
Supports PEM files, remote TLS hosts, and Java keystores (JKS/PKCS12 via keytool).
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

#####################################################################
# Alert.                                                            #
#   - Emits a console message (always, never rate-limited).         #
#   - Logs the alert to ERROR_LOG.                                  #
#   - Optionally sends an email, rate-limited by EMAIL_INTERVAL.    #
#   - Suppressed while maintenance mode is active.                  #
#   - In dry-run mode previews all actions without performing them. #
#####################################################################

alert() {
    local detail="$*"
    local body="Certificate expiring soon on ${HOST_ID}: ${detail}"

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
        echo "$body" | mail -s "Certificate alert on ${HOST_ID}" $ALERT_EMAIL
        mark_email_sent
        log_to "$ERROR_LOG" "EMAIL sent to ${ALERT_EMAIL}"
    else
        echo "Skipping email (rate-limited: last sent $(last_email_age); interval ${EMAIL_INTERVAL}s)" >&2
    fi
}

#########################################################################
# Certificate reading.                                                  #
#   - get_days_until_expiry : receives a parsed type, target, and opts. #
#     Writes the number of days to expiry on stdout.                    #
#     Returns 1 if the certificate cannot be read or parsed,            #
#     so the caller can skip it without crashing.                       #
#                                                                       #
#     Supported types:                                                  #
#       file    - PEM/DER file read by openssl x509.                    #
#       host    - Remote TLS, retrieved via openssl s_client.           #
#       keytool - JKS/PKCS12 keystore checked via keytool -list.        #
#########################################################################

get_days_until_expiry() {
    local type=$1 target=$2 opts=$3
    local enddate exp_epoch days

    case "$type" in

        file)
            [[ -f "$target" ]] || { echo "Warning: file not found: ${target}" >&2; return 1; }
            local ossl; ossl=$(resolve_bin openssl "$OPENSSL_BIN" 2>/dev/null) \
                || { echo "Warning: openssl not found" >&2; return 1; }
            enddate=$("$ossl" x509 -enddate -noout -in "$target" 2>/dev/null | cut -d= -f2) || true
            ;;

        host)
            local ossl; ossl=$(resolve_bin openssl "$OPENSSL_BIN" 2>/dev/null) \
                || { echo "Warning: openssl not found" >&2; return 1; }
            local host port
            host=${target%%:*}
            port=${target##*:}
            [[ "$port" == "$host" ]] && port=443
            enddate=$(echo | "$ossl" s_client \
                -connect "${host}:${port}" -servername "$host" 2>/dev/null \
                | "$ossl" x509 -enddate -noout 2>/dev/null \
                | cut -d= -f2) || true
            ;;

        keytool)
            local ktool; ktool=$(resolve_bin keytool "$KEYTOOL_BIN" 2>/dev/null) \
                || { echo "Warning: keytool not found (set KEYTOOL_BIN or add to PATH)" >&2; return 1; }
            [[ -f "$target" ]] || { echo "Warning: keystore not found: ${target}" >&2; return 1; }
            local pass="${opts:-changeit}"
            # keytool -list -v prints "Valid from: ... until: <date>" for each alias.
            # We pick the soonest expiry across all aliases in the store.
            local earliest_epoch="" alias_epoch
            while IFS= read -r line; do
                if [[ "$line" =~ [Uu]ntil:\ (.+)$ ]]; then
                    local raw_date="${BASH_REMATCH[1]}"
                    alias_epoch=$(date -d "$raw_date" +%s 2>/dev/null) || continue
                    if [[ -z "$earliest_epoch" ]] || (( alias_epoch < earliest_epoch )); then
                        earliest_epoch=$alias_epoch
                    fi
                fi
            done < <("$ktool" -list -v -keystore "$target" -storepass "$pass" 2>/dev/null)

            if [[ -z "$earliest_epoch" ]]; then
                echo "Warning: could not read any expiry date from keystore: ${target}" >&2
                return 1
            fi

            days=$(( (earliest_epoch - $(date +%s)) / 86400 ))
            echo "$days"
            return 0
            ;;

        *)
            echo "Warning: unknown certificate type '${type}' — skipping entry" >&2
            return 1
            ;;
    esac

    # Common path for file and host (keytool returns early above).
    if [[ -z "$enddate" ]]; then
        echo "Warning: could not read certificate from ${type}:${target}" >&2
        return 1
    fi

    exp_epoch=$(date -d "$enddate" +%s 2>/dev/null) || {
        echo "Warning: could not parse end date '${enddate}' for ${target}" >&2
        return 1
    }

    days=$(( (exp_epoch - $(date +%s)) / 86400 ))
    echo "$days"
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

################################################################################
# Main.                                                                        #
#   - Sanity-checks that CERTS is non-empty and resolves tool binaries.        #
#   - Acquires the lock, rotates logs, initializes logging.                    #
#   - In dry-run mode, runs check_prerequisites before anything else.          #
#   - Iterates CERTS; checks each certificate with OpenSSL or keytool.         #
#   - Alerts once per run for all certificates expiring within THRESHOLD_DAYS, #
#     rate-limited to EMAIL_INTERVAL. Suppressed during maintenance mode.      #
################################################################################

(( ${#CERTS[@]} > 0 )) || die "no certificates configured in CERTS"

acquire_lock
rotate_logs
init_logs
(( DRY_RUN )) && check_prerequisites
log_to "$EXECUTION_LOG" "START [${HOST_ID}] checking ${#CERTS[@]} certificate(s)"

expiring=()

for entry in "${CERTS[@]}"; do

    # Skip empty or whitespace-only entries gracefully.
    [[ -z "${entry// }" ]] && continue

    IFS='|' read -r type target opts <<< "$entry"

    # Skip entries where type or target is missing.
    if [[ -z "${type// }" || -z "${target// }" ]]; then
        echo "Warning: incomplete entry '${entry}' — skipping" >&2
        log_to "$EXECUTION_LOG" "SKIP incomplete entry: ${entry}"
        continue
    fi

    label="${type}:${target}"

    days=$(get_days_until_expiry "$type" "$target" "${opts:-}") || {
        log_to "$EXECUTION_LOG" "SKIP unreadable: ${label}"
        continue
    }

    if (( days < THRESHOLD_DAYS )); then
        printf '%b%-50s expires in %s days%b\n' "$RED"   "$label" "$days" "$RST"
        log_to "$EXECUTION_LOG" "RESULT expiring: ${label} in ${days} days"
        expiring+=("${label} (${days} days)")
    else
        printf '%b%-50s expires in %s days%b\n' "$GREEN" "$label" "$days" "$RST"
        log_to "$EXECUTION_LOG" "RESULT ok: ${label} expires in ${days} days"
    fi

done

if (( ${#expiring[@]} > 0 )); then
    # Join all expiring certs into a single alert message.
    local_IFS=$IFS; IFS=', '
    alert "${expiring[*]}"
    IFS=$local_IFS
fi

log_to "$EXECUTION_LOG" "END"
