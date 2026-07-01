# hardware-specs.sh

Lightweight Bash script that collects hardware and system diagnostics, saving each command's output to a separate file under `OUTPUT_DIR/hw_specs/`. Commands that are not installed are skipped gracefully. Designed for quick one-off inventory on virtual machines, bare-metal servers, and containers.

Unlike the monitoring scripts in this collection, this script is **read-only inventory** — it has no alerting, no email, and no status tracking.

---

## Features

- **One file per command** — each diagnostic command writes its output to a separate named file, making it easy to inspect individual components.
- **Graceful skip** — commands not installed on the current system are silently skipped; the rest always run.
- **Non-zero exit handling** — commands that exit with a non-zero code (e.g., `hostnamectl` without systemd) still save their output and are noted in the log.
- **Root warning** — warns when not running as root, since some commands produce partial output without elevated privileges.
- **Optional execution log** — records which commands ran, which were skipped, and their results.
- **Log rotation** — automatic rotation and retention-based pruning of the execution log.
- **Prerequisites check** — `--dry-run` shows which commands are available, which would be skipped, and the exact output paths — without writing anything.
- **Self-contained configuration** — all settings live inside the script.
- **Distro-agnostic** — works on Debian/Ubuntu, RHEL/Fedora, SLES, Arch, Alpine, and any system with Bash.

---

## Requirements

- **Bash 4.x+**

Optional (commands not found are skipped):

- **`lscpu`** — CPU information.
- **`lspci`** — PCI device list.
- **`lsusb`** — USB device list.
- **`lsblk`** — block device tree.
- **`ss`** — open ports and socket statistics.
- **`ip`** — network interfaces and routing table.
- **`hostnamectl`** — hostname and OS metadata (systemd).
- **`systemd-detect-virt`** — virtualisation type detection.
- **`dpkg`** — installed packages (Debian/Ubuntu).
- **`rpm`** — installed packages (RHEL/Fedora/SLES).
- **`dmesg`** — kernel ring buffer (full output).
- **`find`** — for log rotation.

All other commands (`cat`, `uname`, `free`, `df`, `mount`, `ps`, `uptime`) are present on virtually every Linux system.

---

## Installation

### From Git (recommended)

```bash
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/hardware-specs.sh \
     -o /opt/scripts/hardware-specs.sh

wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/hardware-specs.sh \
     -O /opt/scripts/hardware-specs.sh
```

### Manual copy

```bash
cp hardware-specs.sh /opt/scripts/hardware-specs.sh
chmod +x /opt/scripts/hardware-specs.sh
```

### Verify

```bash
/opt/scripts/hardware-specs.sh --version
/opt/scripts/hardware-specs.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script.

### Output directory

```bash
OUTPUT_DIR="${SCRIPT_DIR}/output"
```

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_DIR` | `<script_dir>/output` | Base directory. Files are written to `OUTPUT_DIR/hw_specs/`. Auto-created if missing. |

The default places output next to the script itself. Override for a shared location:

```bash
OUTPUT_DIR="/var/log/diagnostics"
OUTPUT_DIR="/tmp/hw-$(hostname)-$(date +%F)"
```

### Logging

```bash
EXECUTION_LOG="${SCRIPT_DIR}/logs/hardware-specs-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `EXECUTION_LOG` | `<script_dir>/logs/hardware-specs-execution.log` | Records which commands ran, were skipped, or exited non-zero. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Rotate and prune logs older than this. `0` = keep forever. |

To disable logging:

```bash
EXECUTION_LOG=""
```

---

## Usage

```
Usage: hardware-specs.sh [--dry-run] [--version] [--help]

Options:
  --dry-run   Show prerequisites and list what would run without writing anything
  --version   Show version and exit
  --help      Show this help and exit
```

### Basic run

```bash
./hardware-specs.sh
```

```
Note: not running as root; some commands may produce partial output.
  saved  cat /etc/os-release              -> os_release
  saved  uname -a                         -> kernel_info
  saved  hostnamectl                      -> hostname_info (exited non-zero)
  saved  lscpu                            -> cpu_info
  saved  free -h                          -> memory_info
  saved  df -h                            -> disk_usage
  saved  lsblk                            -> block_devices
  saved  mount                            -> mounts
  skip   lspci                        (not installed)
  saved  lsusb                            -> usb_devices
  saved  ip a                             -> network_interfaces
  saved  ip r                             -> routing_table
  saved  cat /etc/resolv.conf             -> dns_config
  saved  ss -tulpn                        -> open_ports
  saved  ps aux --sort=-%cpu              -> process_list_cpu
  saved  systemd-detect-virt              -> vm_detection
  saved  uptime                           -> uptime_info
  saved  dmesg                            -> dmesg_tail
  saved  dpkg -l                          -> installed_packages_deb
  skip   rpm                          (not installed)

Wrote 18 file(s) to /opt/scripts/output/hw_specs (2 command(s) skipped).
```

### Dry-run

```bash
./hardware-specs.sh --dry-run
```

```
Commands:
  cat                              OK
  uname                            OK
  hostnamectl                      OK
  lscpu                            OK
  free                             OK
  df                               OK
  lsblk                            OK
  mount                            OK
  lspci                            MISSING (will skip)
  ...

Configuration:
  Output directory:            /opt/scripts/output/hw_specs
  Execution log:               /opt/scripts/logs/hardware-specs-execution.log
  Log retention:               14 days
  Running as:                  ops (uid=1001)
  Note:                        not root; some commands may give partial output

Dry-run: the following would be executed:
  cat /etc/os-release              -> /opt/scripts/output/hw_specs/os_release
  uname -a                         -> /opt/scripts/output/hw_specs/kernel_info
  lspci -v                         (skipped: not installed)
  ...
```

### With sudo (recommended for full output)

```bash
sudo ./hardware-specs.sh
```

Running as root ensures `dmesg`, `ss -tulpn`, and other privileged commands produce complete output.

---

### Collected files

| Filename | Command | Description |
|---|---|---|
| `os_release` | `cat /etc/os-release` | OS name, version, and ID. |
| `kernel_info` | `uname -a` | Kernel version, architecture, and build date. |
| `hostname_info` | `hostnamectl` | Hostname, OS metadata, and hardware info (systemd). |
| `cpu_info` | `lscpu` | CPU architecture, cores, threads, cache, and flags. |
| `memory_info` | `free -h` | RAM and swap usage in human-readable form. |
| `disk_usage` | `df -h` | Filesystem usage per mount point. |
| `block_devices` | `lsblk` | Block device tree (disks, partitions, LVM). |
| `mounts` | `mount` | All currently mounted filesystems. |
| `pci_devices` | `lspci -v` | PCI device list with vendor and driver info. |
| `usb_devices` | `lsusb` | USB device list. |
| `network_interfaces` | `ip a` | Network interfaces, addresses, and link state. |
| `routing_table` | `ip r` | IP routing table. |
| `dns_config` | `cat /etc/resolv.conf` | DNS resolver configuration. |
| `open_ports` | `ss -tulpn` | Listening TCP/UDP ports with process names. |
| `process_list_cpu` | `ps aux --sort=-%cpu` | All processes sorted by CPU usage. |
| `vm_detection` | `systemd-detect-virt` | Virtualisation type (kvm, vmware, docker, none, etc.). |
| `uptime_info` | `uptime` | System uptime and load averages. |
| `dmesg_tail` | `dmesg` | Full kernel ring buffer (boot messages, hardware events). |
| `installed_packages_deb` | `dpkg -l` | Installed packages (Debian/Ubuntu). |
| `installed_packages_rpm` | `rpm -qa` | Installed packages (RHEL/Fedora/SLES). |

---

## How it works

### Command loop

The script iterates over the `SPECS` list — a heredoc of `filename|command` pairs. For each entry:

1. Extract the first word of the command as the binary name.
2. Check `command -v <binary>` — if not found, print `skip` and continue.
3. Run the full command, redirecting both stdout and stderr to `OUTPUT_DIR/hw_specs/<filename>`.
4. Note if the command exited non-zero — the file is still saved.

Non-zero exit codes are common for commands like `hostnamectl` (requires systemd), `dmesg` (may require root), or `systemd-detect-virt` (may print `none` for bare metal). The output is still useful even with a non-zero exit.

### Output directory structure

```
output/
└── hw_specs/
    ├── os_release
    ├── kernel_info
    ├── hostname_info
    ├── cpu_info
    ├── memory_info
    ├── disk_usage
    ├── block_devices
    ├── mounts
    ├── network_interfaces
    ├── routing_table
    ├── dns_config
    ├── open_ports
    ├── process_list_cpu
    ├── vm_detection
    ├── uptime_info
    ├── dmesg_tail
    ├── installed_packages_deb
    └── ...
```

### Root vs non-root

Some commands require root for full output:

| Command | Without root |
|---|---|
| `dmesg` | May be blocked by `kernel.dmesg_restrict=1` |
| `ss -tulpn` | Shows ports but may omit process names |
| `lspci -v` | May omit driver details |

The script always warns when not running as root. Commands are never skipped due to privilege — they run and save whatever output they produce.

---

## Logging

### Execution log

```
2026-06-20 10:00:01 START output=/opt/scripts/output/hw_specs
2026-06-20 10:00:01 SAVED os_release <- cat /etc/os-release
2026-06-20 10:00:01 SAVED kernel_info <- uname -a
2026-06-20 10:00:01 SAVED (non-zero) hostname_info <- hostnamectl
2026-06-20 10:00:01 SAVED cpu_info <- lscpu
2026-06-20 10:00:02 SKIP lspci
2026-06-20 10:00:02 SKIP rpm
2026-06-20 10:00:02 END saved=18 skipped=2
```

### Log rotation

At every run, the script checks the execution log. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Self-contained — no dependency on `logrotate`.

---

---

## Integration

### Container usage (Docker)

Pass a custom output directory when running inside a container:

```bash
docker run --rm \
  -v /host/output:/output \
  alpine/bash \
  bash /scripts/hardware-specs.sh
```

Set `OUTPUT_DIR` to the mounted path so collected files are accessible from the host.


### Cron (scheduled snapshot)

```cron
0 6 * * * /opt/scripts/hardware-specs.sh >/dev/null 2>&1
```

Saves a fresh snapshot daily at 06:00. Combine with a timestamped `OUTPUT_DIR` to keep history:

```bash
OUTPUT_DIR="/var/log/hw-snapshots/$(date +%F_%H%M%S)" /opt/scripts/hardware-specs.sh
```

### Remote collection via SSH

```bash
# One-liner: run on remote host, capture output locally.
ssh user@server "bash -s" < hardware-specs.sh

# Or copy, run, and retrieve the output directory.
scp hardware-specs.sh user@server:/tmp/
ssh user@server "sudo /tmp/hardware-specs.sh"
scp -r user@server:/tmp/output/hw_specs ./server-specs/
```

### Checkmk / Grafana

The output files are plain text — pipe or cat any of them into your monitoring pipeline. No adapter needed.

## Use cases

### Quick VM inventory

Run once after provisioning a new VM to capture the baseline hardware configuration:

```bash
sudo ./hardware-specs.sh
ls output/hw_specs/
```

### Timestamped snapshots

Create a new output directory per run for historical comparison:

```bash
OUTPUT_DIR="/var/log/hw-snapshots/$(date +%F_%H%M%S)" ./hardware-specs.sh
```

### Remote collection via SSH

```bash
ssh user@server "bash -s" < hardware-specs.sh | tee /local/output.txt
```

Or copy and run:

```bash
scp hardware-specs.sh user@server:/tmp/
ssh user@server "sudo /tmp/hardware-specs.sh"
scp -r user@server:/tmp/output/hw_specs ./server-specs/
```

### Adding custom commands

Add entries to the `SPECS` heredoc in the script:

```bash
SPECS=$(cat <<'LIST'
...existing entries...
selinux_status|getenforce
firewall_rules|iptables -L -n -v
crontabs|crontab -l
LIST
)
```

Each entry is `filename|command`. The first word of the command is used for the availability check.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_DIR` | `<script_dir>/output` | Base output directory. Files written to `OUTPUT_DIR/hw_specs/`. |
| `EXECUTION_LOG` | `<script_dir>/logs/hardware-specs-execution.log` | Run log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Show which commands are available and would run, and their output paths — without writing anything. |
| `--version` | Print version and exit. |
| `--help` | Print usage information and exit. |

---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. |

---

## Author

**Filcu Alexandru**

---

## License

This script is provided as-is for personal and professional use.