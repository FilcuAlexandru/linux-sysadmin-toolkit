#!/usr/bin/env bash

###########################################################################################
# installed-packages.sh                                                                   #
# Bash script that lists installed packages and their versions (Debian/Ubuntu, via dpkg). #
# Author: Filcu Alexandru                                                                 #
###########################################################################################

set -euo pipefail

readonly VERSION="0.1"

usage() {
    cat <<USAGE
Usage: ${0##*/} [--version] [--help]

List installed packages and their versions (Debian/Ubuntu, via dpkg).

Options:
  --version   Show version and exit
  --help      Show this help and exit
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

# Parse arguments.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) echo "Version=${VERSION}"; exit 0 ;;
        --help)    usage; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done

# Sanity check: this targets Debian/Ubuntu (dpkg).
command -v dpkg-query >/dev/null 2>&1 || die "dpkg-query not found (Debian/Ubuntu only; on RHEL use: rpm -qa)"

# Collect installed packages and versions once.
list=$(dpkg-query -W -f='${binary:Package}\t${Version}\n' 2>/dev/null) || die "dpkg-query failed"
count=$(printf '%s\n' "$list" | grep -c .)

# Print an aligned table (header + sorted rows), then the total.
# Alignment is done in awk so there is no dependency on the 'column' command.
{ printf 'PACKAGE\tVERSION\n'; printf '%s\n' "$list" | sort; } | awk -F'\t' '
    { name[NR] = $1; ver[NR] = $2; if (length($1) > w) w = length($1) }
    END { for (i = 1; i <= NR; i++) printf "%-*s  %s\n", w, name[i], ver[i] }'

echo
echo "Total installed packages: ${count}"