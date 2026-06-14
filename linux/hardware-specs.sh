#!/usr/bin/env bash

###########################################################################################
# hardware-specs.sh                                                                       #
# Bash script that collects VM/system diagnostics, saving each command's output to a file #
# under OUTPUT_DIR/vm_specs/. Commands that are not installed are skipped.                #
# Author: Filcu Alexandru                                                                 #
###########################################################################################

set -euo pipefail

readonly VERSION="0.1"
DRY_RUN=0

#########################################################################
# Output configuration (OUTPUT_DIR can be overridden via environment).  #
#   - OUTPUT_DIR : base directory; files go under OUTPUT_DIR/vm_specs/. #
#   - Example: OUTPUT_DIR="/var/log/vm" ./vm-system-info.sh             #
#########################################################################
OUTPUT_DIR="${OUTPUT_DIR:-$PWD}"

usage() {
    cat <<USAGE
Usage: ${0##*/} [--dry-run] [--version] [--help]

Collect VM/system diagnostics into OUTPUT_DIR/vm_specs/ (one file per command).
Commands that are not installed are skipped; some commands need root for full output.

Options:
  --dry-run   List what would run and where, without writing anything
  --version   Show version and exit
  --help      Show this help and exit
USAGE
}

die() { echo "Error: $*" >&2; exit 1; }

# Parse arguments                                                             
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) echo "Version=${VERSION}"; exit 0 ;;
        --help)    usage; exit 0 ;;
        *)         die "unknown option: $1" ;;
    esac
done


# Each line is "output_filename|command to run"                            
specs=$(cat <<'LIST'
os_release|cat /etc/os-release
kernel_info|uname -a
hostname|hostnamectl
uptime|uptime
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
process_list|ps aux --sort=-%cpu | head -20
vm_detection|systemd-detect-virt
dmesg_tail|dmesg | tail -50
installed_packages_deb|dpkg -l
installed_packages_rpm|rpm -qa
LIST
)

dir="${OUTPUT_DIR}/vm_specs"

[[ $EUID -eq 0 ]] || echo "Note: not running as root; some commands may produce partial output." >&2


# Dry-run mode                                                               
if (( DRY_RUN )); then
    echo "[dry-run] would create: $dir"
    while IFS='|' read -r fname cmd; do
        [[ -z "$fname" ]] && continue
        bin=${cmd%% *}
        if command -v "$bin" >/dev/null 2>&1; then
            echo "[dry-run] would run : ${cmd}  ->  ${fname}"
        else
            echo "[dry-run] would skip: ${cmd} (not installed)"
        fi
    done <<< "$specs"
    exit 0
fi

mkdir -p "$dir" || die "cannot create $dir"

saved=0; skipped=0


# Execution loop                                                             
while IFS='|' read -r fname cmd; do
    [[ -z "$fname" ]] && continue
    bin=${cmd%% *}

    if ! command -v "$bin" >/dev/null 2>&1; then
        printf 'skip   %-28s (not installed)\n' "$cmd"
        skipped=$((skipped + 1))
        continue
    fi

    read -ra parts <<< "$cmd"

    if "${parts[@]}" > "${dir}/${fname}" 2>&1; then
        printf 'saved  %-28s -> %s\n' "$cmd" "$fname"
    else
        printf 'saved  %-28s -> %s (exited non-zero)\n' "$cmd" "$fname"
    fi

    saved=$((saved + 1))
done <<< "$specs"

echo
echo "Wrote ${saved} file(s) to ${dir} (${skipped} command(s) skipped as not installed)."