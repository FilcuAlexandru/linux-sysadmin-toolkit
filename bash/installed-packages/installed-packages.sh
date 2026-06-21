#!/usr/bin/env bash

###############################################################################
# installed-packages.sh                                                       #
# Bash script that lists installed packages and their versions.               #
# Supports Debian/Ubuntu (dpkg), RHEL/Fedora (rpm), Arch (pacman),            #
# SLES/openSUSE (zypper), and Alpine (apk). Auto-detects the package manager. #
# Author: Filcu Alexandru                                                     #
###############################################################################

set -euo pipefail

readonly VERSION="0.1"

####################################################################
# Script directory (auto-detected; used as default base for logs). #
# Override if needed.                                              #
####################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

##############################################################################
# Output configuration.                                                      #
#   - OUTPUT_FORMAT : 'table' (aligned columns, default) or 'plain'          #
#                     (one package per line as name=version, for scripting). #
#   - SHOW_TOTAL    : set to 1 to print the total count (default: 1).        #
##############################################################################

OUTPUT_FORMAT="table"
SHOW_TOTAL=1

############################################################################
# Logging (optional).                                                      #
#   - Output can be saved to LOG_FILE on each run.                         #
#   - Set LOG_FILE to empty ("") to disable.                               #
#   - LOG_RETENTION_DAYS : rotate files older than this. 0 = keep forever. #
############################################################################

LOG_FILE=""
LOG_RETENTION_DAYS="14"

#########################################################
# Script logic below; no changes needed past this line. #
#########################################################

DRY_RUN=0

# Colors only when writing to a terminal, keeping pipe and redirect output clean.
if [[ -t 1 ]]; then GREEN=$'\e[32m'; RED=$'\e[31m'; RST=$'\e[0m'; else GREEN=""; RED=""; RST=""; fi

#######################################################################
# Prerequisites check.                                                #
#   - detect_package_manager : probes available package manager tools #
#                              in priority order and returns the name #
#                              of the first one found.                #
#   - check_prerequisites    : prints each tool's availability and    #
#                              the active configuration. Called       #
#                              automatically by --dry-run.            #
#######################################################################

# Detect which package manager is available, in priority order.
# Prints the manager name to stdout; returns 1 if none found.
detect_package_manager() {
    if command -v dpkg-query >/dev/null 2>&1; then echo "dpkg";    return 0; fi
    if command -v rpm       >/dev/null 2>&1; then echo "rpm";     return 0; fi
    if command -v pacman    >/dev/null 2>&1; then echo "pacman";  return 0; fi
    if command -v zypper    >/dev/null 2>&1; then echo "zypper";  return 0; fi
    if command -v apk       >/dev/null 2>&1; then echo "apk";     return 0; fi
    return 1
}

check_prerequisites() {
    local ok="${GREEN}OK${RST}" miss="${RED}MISSING${RST}" dis="${RED}DISABLED${RST}"
    local found_any=0

    echo "Package managers (first available will be used):"
    for mgr in dpkg-query rpm pacman zypper apk; do
        if command -v "$mgr" >/dev/null 2>&1; then
            printf '  %-28s %b\n' "$mgr" "$ok"
            found_any=1
        else
            printf '  %-28s %b\n' "$mgr" "$miss"
        fi
    done
    (( found_any )) || echo "  WARNING: no supported package manager found"

    echo
    echo "Optional tools:"
    if command -v find >/dev/null 2>&1; then
        printf '  %-28s %b\n' "find" "$ok"
    else
        printf '  %-28s %b (log rotation disabled)\n' "find" "$miss"
    fi

    echo
    echo "Configuration:"
    printf '  %-28s %s\n' "Output format:"   "$OUTPUT_FORMAT"
    printf '  %-28s %s\n' "Show total:"      "$( (( SHOW_TOTAL )) && echo yes || echo no )"
    if [[ -n "$LOG_FILE" ]]; then
        printf '  %-28s %s\n'    "Log file:"       "$LOG_FILE"
        printf '  %-28s %s days\n' "Log retention:" "$LOG_RETENTION_DAYS"
    else
        printf '  %-28s %b\n' "Log file:" "$dis"
    fi
    echo
}

###################################################################
# Log rotation.                                                   #
#   - rotate_log : archives LOG_FILE when it is older than        #
#                  LOG_RETENTION_DAYS and deletes archived copies #
#                  past the same window. Skipped if find(1) is    #
#                  unavailable or LOG_RETENTION_DAYS is 0.        #
###################################################################

rotate_log() {
    [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] || return 0
    (( LOG_RETENTION_DAYS > 0 ))            || return 0
    command -v find >/dev/null 2>&1         || return 0

    local base dir
    base=$(basename "$LOG_FILE"); dir=$(dirname "$LOG_FILE")

    if [[ -n $(find "$dir" -maxdepth 1 -name "$base" -mtime +"$LOG_RETENTION_DAYS" 2>/dev/null) ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.$(date +%F_%H%M%S)" 2>/dev/null || true
    fi
    find "$dir" -maxdepth 1 -type f -name "${base}.*" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

################################################################
# CLI.                                                         #
#   - usage : prints the help text to stdout.                  #
#   - die   : prints an error to stderr and exits with code 1. #
################################################################

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

List installed packages and their versions.
Auto-detects the package manager: dpkg (Debian/Ubuntu), rpm (RHEL/Fedora/SLES),
pacman (Arch), zypper (openSUSE), apk (Alpine).

Options:
  --dry-run   Check prerequisites and show configuration without listing packages
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

######################################################################
# Package list fetching.                                             #
#   - fetch_packages : queries the detected package manager and      #
#                      writes tab-separated 'name<TAB>version' lines #
#                      to stdout. Handles dpkg, rpm, pacman, zypper, #
#                      and apk. Returns 1 if no manager is found.    #
######################################################################

# Query the package manager and write 'name<TAB>version' lines to stdout.
fetch_packages() {
    local mgr=$1

    case "$mgr" in
        dpkg)
            dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null
            ;;
        rpm)
            rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n' 2>/dev/null \
                | sort
            ;;
        pacman)
            pacman -Q 2>/dev/null \
                | awk '{print $1 "\t" $2}'
            ;;
        zypper)
            zypper --quiet --non-interactive packages --installed-only 2>/dev/null \
                | awk -F'|' 'NR>2 && $3~/i/{gsub(/ /,"",$4); gsub(/ /,"",$5); print $4 "\t" $5}'
            ;;
        apk)
            apk info -v 2>/dev/null \
                | awk -F'-' '{ver=$NF; name=substr($0,1,length($0)-length(ver)-1); print name "\t" ver}'
            ;;
    esac
}

#####################################################################
# Output formatting.                                                #
#   - print_table : reads tab-separated input and prints an aligned #
#                   two-column table (PACKAGE / VERSION) using awk. #
#                   No dependency on the 'column' command.          #
#   - print_plain : prints one 'name=version' line per package.     #
#                   Suitable for piping to grep, sort, diff, etc.   #
#####################################################################

# Print an aligned two-column table using awk (no 'column' dependency).
print_table() {
    { printf 'PACKAGE\tVERSION\n'; cat; } | awk -F'\t' '
        { name[NR] = $1; ver[NR] = $2; if (length($1) > w) w = length($1) }
        END { for (i = 1; i <= NR; i++) printf "%-*s  %s\n", w, name[i], ver[i] }'
}

# Print one 'name=version' line per package (for scripting).
print_plain() {
    awk -F'\t' '{ printf "%s=%s\n", $1, $2 }'
}

#########
# Main. #
#########

(( DRY_RUN )) && { check_prerequisites; exit 0; }

mgr=$(detect_package_manager) || die "no supported package manager found (tried: dpkg rpm pacman zypper apk)"

rotate_log

# Fetch and sort package list.
list=$(fetch_packages "$mgr" | sort) || die "failed to query packages via ${mgr}"
[[ -n "$list" ]] || die "no packages returned by ${mgr}"

count=$(printf '%s\n' "$list" | grep -c .)

# Render output in the chosen format, optionally saving to LOG_FILE.
if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    {
        printf '# installed-packages.sh — %s — %s — %s packages\n' \
            "$(date '+%F %H:%M:%S')" "$mgr" "$count"
        case "$OUTPUT_FORMAT" in
            plain) printf '%s\n' "$list" | print_plain ;;
            *)     printf '%s\n' "$list" | print_table ;;
        esac
    } | tee "$LOG_FILE"
else
    case "$OUTPUT_FORMAT" in
        plain) printf '%s\n' "$list" | print_plain ;;
        *)     printf '%s\n' "$list" | print_table ;;
    esac
fi

if (( SHOW_TOTAL )); then
    echo
    echo "Total installed packages: ${count} (via ${mgr})"
fi