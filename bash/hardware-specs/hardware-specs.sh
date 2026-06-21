#!/usr/bin/env bash

##########################################################################
# hardware-specs.sh                                                      #
# Bash script that collects hardware and system diagnostics, saving each #
# command's output to a separate file under OUTPUT_DIR/hw_specs/.        #
# Commands that are not installed are skipped gracefully.                #
# Author: Filcu Alexandru                                                #
##########################################################################

set -euo pipefail

readonly VERSION="0.1"

####################################################################
# Script directory (auto-detected; used as default base for logs). #
# Override if needed.                                              #
####################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

###############################################################
# Output directory.                                           #
#   - Collected files are written under OUTPUT_DIR/hw_specs/. #
#   - The directory is created if it does not exist.          #
#   - Example: OUTPUT_DIR="/var/log/diagnostics"              #
###############################################################

OUTPUT_DIR="${SCRIPT_DIR}/output"

############################################################################
# Logging (optional).                                                      #
#   - EXECUTION_LOG : records which commands ran and which were skipped.   #
#   - Set to empty ("") to disable.                                        #
#   - LOG_RETENTION_DAYS : rotate files older than this. 0 = keep forever. #
############################################################################

EXECUTION_LOG="${SCRIPT_DIR}/logs/hardware-specs-execution.log"
LOG_RETENTION_DAYS="14"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal, keeping pipe and redirect output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

##########################################################################
# Spec list.                                                             #
#   - Each entry is a pipe-separated pair: filename|command.             #
#   - filename : base name (no extension) of the output file.            #
#   - command  : shell command to run; its stdout+stderr go to the file. #
#   - Commands that need root produce partial output when run as a       #
#     regular user; they are not skipped, just noted.                    #
##########################################################################

# Each line: filename|command
# The first word of the command is used for availability checking.
# Output (stdout + stderr) is saved to OUTPUT_DIR/hw_specs/<filename>.
SPECS=$(cat <<'LIST'
os_release|cat /etc/os-release
kernel_info|uname -a
hostname_info|hostnamectl
cpu_info|lscpu
memory_info|free -h
disk_usage|df -h
block_devices|lsblk
mounts|mount
pci_devices|lspci -v
usb_devices|lsusb
network_interfaces|ip a
routing_table|ip r
dns_config|cat /etc/resolv.conf
open_ports|ss -tulpn
process_list_cpu|ps aux --sort=-%cpu
vm_detection|systemd-detect-virt
uptime_info|uptime
dmesg_tail|dmesg
installed_packages_deb|dpkg -l
installed_packages_rpm|rpm -qa
LIST
)

########################################################################
# Prerequisites check.                                                 #
#   - Shows which commands from the SPECS list are available and which #
#     would be skipped, plus the active output configuration.          #
#   - Called automatically by --dry-run.                               #
########################################################################

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING (will skip)${RST}"

    echo "Commands:"
    while IFS='|' read -r fname cmd; do
        [[ -z "$fname" ]] && continue
        local bin="${cmd%% *}"
        if command -v "$bin" >/dev/null 2>&1; then
            printf '  %-32s %b\n' "$bin" "$ok"
        else
            printf '  %-32s %b\n' "$bin" "$miss"
        fi
    done <<< "$SPECS"

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Output directory:"  "${OUTPUT_DIR}/hw_specs"
    if [[ -n "$EXECUTION_LOG" ]]; then
        printf '  %-28s %s\n' "Execution log:"  "$EXECUTION_LOG"
        printf '  %-28s %s days\n' "Log retention:" "$LOG_RETENTION_DAYS"
    else
        printf '  %-28s %s\n' "Execution log:"  "disabled"
    fi
    printf '  %-28s %s\n' "Running as:" "$(id -un) (uid=${EUID})"
    (( EUID == 0 )) || printf '  %-28s %s\n' "Note:" "not root; some commands may give partial output"
    echo
}

###################################################################
# Log rotation.                                                   #
#   - rotate_log : archives EXECUTION_LOG when it is older than   #
#                  LOG_RETENTION_DAYS, then deletes old archives. #
#                  Skipped if find(1) is unavailable or           #
#                  LOG_RETENTION_DAYS is 0.                       #
###################################################################

rotate_log() {
    [[ -n "$EXECUTION_LOG" && -f "$EXECUTION_LOG" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))            || return 0
    command -v find >/dev/null 2>&1         || return 0

    local base dir
    base=$(basename "$EXECUTION_LOG"); dir=$(dirname "$EXECUTION_LOG")

    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" \
                   -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$EXECUTION_LOG" "${EXECUTION_LOG}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi
    find "$dir" -maxdepth 1 -type f -name "${base}.*" \
         -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

log_to() {
    [[ -n "$EXECUTION_LOG" ]] || return 0
    printf '%s %s\n' "$(date '+%F %H:%M:%S')" "$*" >> "$EXECUTION_LOG" 2>/dev/null || true
}

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Collect hardware and system diagnostics into OUTPUT_DIR/hw_specs/.
One file per command; commands not installed are skipped gracefully.
Some commands produce partial output when run without root privileges.

Options:
  --dry-run   Show prerequisites and list what would run without writing anything
  --version   Show version and exit
  --help      Show this help and exit
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) echo "Version=${VERSION}"; exit 0 ;;
        --help)    usage; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

#############################################################################
# Main.                                                                     #
#   - Checks for root and warns if not (some commands produce less output). #
#   - Creates OUTPUT_DIR/hw_specs/.                                         #
#   - Iterates over SPECS: skips commands not in PATH, runs the rest.       #
#   - Prints a summary (saved / skipped) and logs to EXECUTION_LOG.         #
#############################################################################

(( EUID == 0 )) || echo "Note: not running as root; some commands may produce partial output." >&2

if (( DRY_RUN )); then
    check_prerequisites
    echo "Dry-run: the following would be executed:"
    while IFS='|' read -r fname cmd; do
        [[ -z "$fname" ]] && continue
        local_bin="${cmd%% *}"
        if command -v "$local_bin" >/dev/null 2>&1; then
            printf '  %b%-32s%b -> %s\n' "$GREEN" "$cmd" "$RST" "${OUTPUT_DIR}/hw_specs/${fname}"
        else
            printf '  %b%-32s%b (skipped: not installed)\n' "$RED" "$cmd" "$RST"
        fi
    done <<< "$SPECS"
    exit 0
fi

dir="${OUTPUT_DIR}/hw_specs"
mkdir -p "$dir" || die "cannot create output directory: $dir"

# Init log after output dir is confirmed creatable.
if [[ -n "$EXECUTION_LOG" ]]; then
    mkdir -p "$(dirname "$EXECUTION_LOG")" 2>/dev/null || EXECUTION_LOG=""
    [[ -n "$EXECUTION_LOG" ]] && touch "$EXECUTION_LOG" 2>/dev/null || EXECUTION_LOG=""
fi

rotate_log
log_to "START output=${dir}"

saved=0; skipped=0

while IFS='|' read -r fname cmd; do
    [[ -z "$fname" ]] && continue
    local_bin="${cmd%% *}"

    if ! command -v "$local_bin" >/dev/null 2>&1; then
        printf '%b  skip   %b%-32s%b (not installed)\n' "$RED" "$RST" "$local_bin" "$RST"
        log_to "SKIP ${local_bin}"
        skipped=$(( skipped + 1 ))
        continue
    fi

    outfile="${dir}/${fname}"
    read -ra parts <<< "$cmd"

    if "${parts[@]}" > "$outfile" 2>&1; then
        printf '%b  saved  %b%-36s%b -> %s\n' "$GREEN" "$RST" "$cmd" "$RST" "$fname"
        log_to "SAVED ${fname} <- ${cmd}"
    else
        printf '%b  saved  %b%-36s%b -> %s (exited non-zero)\n' "$GREEN" "$RST" "$cmd" "$RST" "$fname"
        log_to "SAVED (non-zero) ${fname} <- ${cmd}"
    fi
    saved=$(( saved + 1 ))
done <<< "$SPECS"

echo
printf 'Wrote %d file(s) to %s (%d command(s) skipped).\n' "$saved" "$dir" "$skipped"
log_to "END saved=${saved} skipped=${skipped}"