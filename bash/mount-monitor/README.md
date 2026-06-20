# mount-monitor.sh

Lightweight Bash script that checks whether one or more expected mountpoints are mounted and alerts when any of them are missing. Designed for Linux servers where NFS shares, SAN volumes, or other network/block storage must be reliably available.

Reads directly from the kernel (`/proc/self/mounts`) with automatic fallback to standard commands, so it works on any Linux distribution — Debian, Ubuntu, RHEL, SLES, Gentoo, Alpine, NixOS — without additional dependencies.

---

## Features

- **Kernel-first detection** — reads `/proc/self/mounts` (no external binary needed); falls back to `mountpoint(1)` then `mount(1)` if `/proc` is unavailable.
- **Multi-mount support** — configure any number of mountpoints in a single array.
- **Color-coded terminal output** — green for mounted, red for not mounted; colors are automatically suppressed in cron, pipes, and redirects.
- **Email alerts with rate-limiting** — optional email notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour) to avoid inbox flooding.
- **Structured logging** — optional execution log (every run) and error log (only when issues are found), with automatic rotation and retention-based pruning.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external monitoring system.
- **Dry-run mode** — preview all actions (alerts, emails, logging) without actually firing anything.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies.

---

## Requirements

- **Bash 4.x+** (present on virtually all modern Linux systems).
- **Linux kernel with `/proc` mounted** (standard on all distributions).
- **`mail` command** (optional, only needed for email alerts; provided by `mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** (optional, only needed for email delivery; e.g., Postfix, msmtp, ssmtp).

No other dependencies. The script does not require `root`, though it does need read access to `/proc/self/mounts` and to the mountpoints being checked.

---

## Installation

```bash
# Copy the script to a directory of your choice.
cp mount-monitor.sh /opt/scripts/mount-monitor.sh
chmod +x /opt/scripts/mount-monitor.sh

# (Optional) Verify it works.
/opt/scripts/mount-monitor.sh --help
/opt/scripts/mount-monitor.sh --version
```

No `make`, no `pip install`, no package manager. One file, copy and run.

---

## Configuration

All configuration is done through variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Mountpoints

```bash
MOUNTS=("/mnt/data" "/mnt/backup")
```

Add or remove paths as needed. Each path is checked independently; the script alerts on whichever ones are not mounted.

```bash
# Single mount
MOUNTS=("/mnt/nfs-share")

# Multiple mounts
MOUNTS=("/mnt/data" "/mnt/backup" "/srv/nfs" "/mnt/san-vol01")
```

### Email alerts

```bash
ALERT_EMAIL="${ALERT_EMAIL:-}"
EMAIL_INTERVAL="${EMAIL_INTERVAL:-3600}"
STATE_FILE="${STATE_FILE:-${TMPDIR:-/tmp}/mount-monitor.email.state}"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | *(empty = disabled)* | Recipient address. Set to enable email alerts. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown regardless of this setting. |
| `STATE_FILE` | `/tmp/mount-monitor.email.state` | File that stores the timestamp of the last sent email. |

Email can be configured in the script or passed via environment without editing the file:

```bash
ALERT_EMAIL="ops@example.com" ./mount-monitor.sh
ALERT_EMAIL="ops@example.com" EMAIL_INTERVAL=1800 ./mount-monitor.sh   # every 30 min
```

### Logging

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR-${SCRIPT_DIR}/logs}"
ERROR_LOG="${ERROR_LOG-${LOG_DIR}/mount-monitor-error.log}"
EXECUTION_LOG="${EXECUTION_LOG-${LOG_DIR}/mount-monitor-execution.log}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-14}"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory where log files are created. Auto-created if it does not exist. |
| `ERROR_LOG` | `<LOG_DIR>/mount-monitor-error.log` | Log file for alerts and errors only. Set to `""` to disable. |
| `EXECUTION_LOG` | `<LOG_DIR>/mount-monitor-execution.log` | Log file for every run (start, result, end). Set to `""` to disable. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this many days. Set to `0` to keep logs forever. |

Logging is fully optional. The script works identically without it — if the log directory cannot be created or a log file cannot be written, a warning is printed and the script continues.

To disable logging entirely:

```bash
ERROR_LOG="" EXECUTION_LOG="" ./mount-monitor.sh
```

To disable only the error log:

```bash
ERROR_LOG="" ./mount-monitor.sh
```

To use a custom log directory:

```bash
LOG_DIR="/var/log/mount-monitor" ./mount-monitor.sh
```

---

## Usage

```
Usage: mount-monitor.sh [--dry-run] [--version] [--help]

Options:
  --dry-run   Preview the alert action (and email decision) without firing it
  --version   Show version and exit
  --help      Show this help and exit
```

### Basic run

```bash
./mount-monitor.sh
```

Output:

```
/mnt/data                      mounted
/mnt/backup                    NOT mounted
ALERT: Mountpoints not mounted on hostname: /mnt/backup
```

### Dry-run

```bash
./mount-monitor.sh --dry-run
```

Output:

```
/mnt/data                      mounted
/mnt/backup                    NOT mounted
[dry-run] would raise alert: /mnt/backup
[dry-run] would email: ops@example.com (last sent: 1200s ago)
```

Shows exactly what would happen without actually sending emails or writing to logs differently than normal. Useful for testing configuration changes.

---

## How it works

### Mount detection (source priority)

The script checks each configured mountpoint using a three-level fallback chain:

1. **`/proc/self/mounts`** (preferred) — the kernel's own list of active mounts. Read directly by Bash line-by-line, no external binary needed. Present on every standard Linux system.

2. **`mountpoint -q`** (fallback 1) — the `mountpoint` command from `util-linux`. Used only if `/proc/self/mounts` is not readable (rare: certain chroot or container environments).

3. **`mount` command** (fallback 2) — parses the output of `mount(1)` with `awk`. Used only if neither of the above is available.

If none of the three sources are available, the script exits with a clear error message. In practice, `/proc/self/mounts` is always available on Linux systems, so the fallbacks exist purely for robustness.

### Alert flow

```
Mountpoint check
    │
    ├── All mounted ──────── Print green status ── Log "all mounted" ── Exit
    │
    └── Some not mounted
            │
            ├── Print red status (console, always)
            ├── Log to ERROR_LOG (if enabled)
            ├── Log to EXECUTION_LOG (if enabled)
            │
            └── Email?
                 ├── ALERT_EMAIL not set ──── Skip
                 ├── Rate-limited ──────────── Skip (print notice)
                 └── Interval passed ──────── Send email ── Update STATE_FILE
```

Console alerts are never rate-limited — you always see the current state. Only email delivery is throttled.

---

## Logging

### Directory structure

```
scripts/
├── mount-monitor.sh
└── logs/
    ├── mount-monitor-error.log
    ├── mount-monitor-error.log.2026-06-01_120000       ← rotated archive
    ├── mount-monitor-execution.log
    └── mount-monitor-execution.log.2026-06-01_120000   ← rotated archive
```

The `logs/` directory is created automatically next to the script. Override with `LOG_DIR`.

### Execution log

Records every run, regardless of outcome:

```
2026-06-20 10:00:01 START checking 3 mount(s): /mnt/data /mnt/backup /srv/nfs
2026-06-20 10:00:01 RESULT all mounted
2026-06-20 10:00:01 END
```

```
2026-06-20 11:00:01 START checking 3 mount(s): /mnt/data /mnt/backup /srv/nfs
2026-06-20 11:00:01 RESULT 1 unmounted: /mnt/backup
2026-06-20 11:00:01 END
```

### Error log

Records only alerts and email actions:

```
2026-06-20 11:00:01 ALERT /mnt/backup
2026-06-20 11:00:01 EMAIL sent to ops@example.com
```

If nothing is wrong, this file stays empty — making it easy to monitor externally (e.g., `test -s mount-monitor-error.log`).

### Log rotation

At every run, the script checks each active log file:

1. If the file's modification time is older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix (e.g., `.2026-06-01_120000`) and a fresh log is started.
2. Archived copies (files matching `<logname>.*`) older than `LOG_RETENTION_DAYS` are deleted.

This is self-contained — no dependency on `logrotate` or external cron jobs. Set `LOG_RETENTION_DAYS=0` to disable rotation entirely.

---

## Integration

### Cron (recommended for periodic checks)

```cron
# Check mounts every 5 minutes.
*/5 * * * * /opt/scripts/mount-monitor.sh 2>&1 | logger -t mount-monitor
```

Or with email alerts:

```cron
*/5 * * * * ALERT_EMAIL="ops@example.com" /opt/scripts/mount-monitor.sh 2>/dev/null
```

The email rate-limiting ensures you receive at most one email per hour (or whatever `EMAIL_INTERVAL` is set to), even though the check runs every 5 minutes.

### Checkmk (local check)

Place the script (or a wrapper) in the Checkmk local checks directory:

```bash
cp mount-monitor.sh /usr/lib/check_mk_agent/local/mount-monitor.sh
```

To produce Checkmk-compatible output, wrap the `alert()` function or add a simple adapter that translates the exit code and output format. The function is designed as a seam — replace its body with Checkmk-specific output without touching the rest of the script.

### Grafana / Prometheus (textfile collector)

Write a small adapter in `alert()` that outputs a Prometheus metric to a `.prom` file:

```bash
# Inside alert(), add:
echo "mount_monitor_down{host=\"$(hostname)\"} ${#down[@]}" > /var/lib/node_exporter/mount-monitor.prom
```

The Node Exporter textfile collector will pick it up automatically.

### systemd timer (alternative to cron)

Create a service and timer unit:

```ini
# /etc/systemd/system/mount-monitor.service
[Unit]
Description=Mount monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/mount-monitor.sh
Environment=ALERT_EMAIL=ops@example.com
```

```ini
# /etc/systemd/system/mount-monitor.timer
[Unit]
Description=Run mount monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now mount-monitor.timer
```

---

## Use cases

### NFS shares on application servers

Monitor NFS mounts that must be available for an application to function. Alert the operations team immediately when a share drops, before users notice.

```bash
MOUNTS=("/mnt/app-data" "/mnt/shared-config" "/mnt/logs-nfs")
ALERT_EMAIL="app-ops@company.com"
EMAIL_INTERVAL=1800   # alert every 30 minutes while the mount is down
```

### Backup volumes

Ensure that the backup target is mounted before a backup job runs. Run `mount-monitor.sh` as a pre-check in your backup script or cron:

```bash
if ! /opt/scripts/mount-monitor.sh >/dev/null 2>&1; then
    echo "Backup aborted: required mounts are missing" >&2
    exit 1
fi
# ... proceed with backup
```

### Multi-environment infrastructure (e.g., eIP platform)

Monitor different sets of mounts per environment by overriding `MOUNTS` via a wrapper or environment:

```bash
# production.sh
export MOUNTS=("/mnt/prod-data" "/mnt/prod-logs" "/mnt/prod-archive")
export ALERT_EMAIL="prod-ops@company.com"
/opt/scripts/mount-monitor.sh
```

### Minimal / containerized systems

On Alpine, BusyBox, or slim containers where `mountpoint` and `mount` may not be available, the script still works — it reads `/proc/self/mounts` directly with pure Bash.

---

## File overview

```
mount-monitor.sh          The script (single file, no dependencies)
logs/                     Auto-created log directory (next to the script)
  mount-monitor-error.log       Alerts and errors only
  mount-monitor-execution.log   Every run (start, result, end)
```

---

## Environment variable reference

All variables can be set in the script or passed via environment.

| Variable | Default | Description |
|---|---|---|
| `MOUNTS` | `("/mnt/data" "/mnt/backup")` | Array of mountpoints to check. |
| `ALERT_EMAIL` | *(empty)* | Email recipient. Empty = email disabled. |
| `EMAIL_INTERVAL` | `3600` | Seconds between emails. |
| `STATE_FILE` | `/tmp/mount-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/mount-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/mount-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |

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