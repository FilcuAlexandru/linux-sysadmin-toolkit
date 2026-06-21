# disk-usage-monitor.sh

Lightweight Bash script that monitors disk usage per filesystem, highlights any that exceed a configurable threshold, and sends smart alerts. Tracks state per filesystem — alerts once when a filesystem first breaches the threshold, stays silent while it remains above it, and sends a recovery email when it drops back below.

---

## Features

- **Per-filesystem display** — shows the full `df` table with color-coding (red = above threshold).
- **Per-filesystem status tracking** — alerts once on first breach, stays silent while above threshold, recovers once when it drops below.
- **Filesystem exclusions** — skip unwanted types (tmpfs, devtmpfs, squashfs, overlay, etc.) and mountpoint prefixes by configuration.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency, the current alert state, and the active configuration.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **`df`** — required for reading disk usage (present on all Linux systems).
- **`awk`** — required for table parsing (present on all Linux systems).

Optional (the script warns and continues without them):

- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for instance locking (`util-linux`).
- **`find`** — for log rotation (`findutils`).

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/disk-usage-monitor.sh \
     -o /opt/scripts/disk-usage-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/disk-usage-monitor.sh \
     -O /opt/scripts/disk-usage-monitor.sh
```

### Manual copy

```bash
cp disk-usage-monitor.sh /opt/scripts/disk-usage-monitor.sh
chmod +x /opt/scripts/disk-usage-monitor.sh
```

### Verify

```bash
/opt/scripts/disk-usage-monitor.sh --version
/opt/scripts/disk-usage-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Threshold

```bash
THRESHOLD=80
```

Alert fires when any filesystem's usage exceeds this percentage. Set between `0` and `100`.

### Filesystem exclusions

```bash
EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay iso9660"
EXCLUDE_MOUNT=""
```

| Variable | Default | Description |
|---|---|---|
| `EXCLUDE_TYPES` | `tmpfs devtmpfs squashfs overlay iso9660` | Space-separated list of filesystem types to skip. |
| `EXCLUDE_MOUNT` | `""` *(none)* | Space-separated list of mountpoint prefixes to skip. |

#### Excluding by type

```bash
# Default — skip virtual/non-storage filesystems.
EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay iso9660"

# Also exclude FUSE filesystems.
EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay iso9660 fuse.rclone fuse.sshfs"
```

#### Excluding by mountpoint prefix

```bash
# Skip all mounts under /run, /sys, /proc, /dev.
EXCLUDE_MOUNT="/run /sys /proc /dev"

# Skip a specific NFS share temporarily.
EXCLUDE_MOUNT="/mnt/old-nfs"
```

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/disk-usage-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/disk-usage-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com infra@example.com manager@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/disk-usage-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/disk-usage-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/disk-usage-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/disk-usage-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

To disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="storage-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable → `hostname` command → `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/disk-usage-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/disk-usage-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/disk-usage-monitor.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: disk-usage-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./disk-usage-monitor.sh
```

```
Filesystem      Type    Size  Used Avail Use% Mounted on
/dev/sda1       ext4    100G   85G   15G  85% /
/dev/sdb1       ext4    500G  100G  400G  20% /data
/dev/sdc1       xfs     200G   50G  150G  25% /var/log
ALERT: Disk usage above 80% on app-prod-01: /
```

The `/` row appears in red on terminal. `/data` and `/var/log` appear in the normal color.

### Dry-run

```bash
./disk-usage-monitor.sh --dry-run
```

```
Prerequisites:
  df                           OK
  awk                          OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Threshold:                   80%
  Exclude types:               tmpfs devtmpfs squashfs overlay iso9660
  Exclude mounts:              /run /sys
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/disk-usage-monitor-error.log
  Execution log:               /opt/scripts/logs/disk-usage-monitor-execution.log
  Log retention:               14 days

State:
  Currently in ALERT:          /
  Maintenance mode:            off
  Last email:                  1823s ago
  Lock directory writable:     OK

Filesystem      Type    Size  Used Avail Use% Mounted on
/dev/sda1       ext4    100G   85G   15G  85% /
/dev/sdb1       ext4    500G  100G  400G  20% /data
[dry-run] would raise alert: /
[dry-run] would skip email (rate-limited: last sent 1823s ago; interval 3600s)
```

Note: in dry-run mode the alert is shown but the alert state is not updated, so the status file stays unchanged.

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./disk-usage-monitor.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./disk-usage-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Alert lifecycle (per filesystem)

Each filesystem is tracked independently:

```
                    ┌─────────────┐
                    │  not in     │
                    │  ALERT list │
                    └──────┬──────┘
                           │
              usage > THRESHOLD (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► add to ALERT list
                    │ (aggregated)│
                    └──────┬──────┘
                           │
              usage still > THRESHOLD (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► remains in ALERT list
                    └──────┬──────┘
                           │
              usage <= THRESHOLD
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► remove from ALERT list
                    └───────────────┘
```

If multiple filesystems breach the threshold on the same run, a single alert email lists all of them. Recovery emails are sent individually, one per filesystem, as each recovers.

### State file format

`STATUS_FILE` holds a space-separated list of mountpoints currently in ALERT state:

```
/ /data /var/log
```

When all filesystems are below the threshold the file is empty. The file is updated on every state change (breach or recovery).

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next run that detects new breaches, the script checks whether `EMAIL_INTERVAL` seconds have passed. If not, the alert is logged but the email is skipped.

Recovery emails are never rate-limited — each recovery is a distinct event.

### Filesystem exclusions

Exclusions are applied before any threshold check or status update. A filesystem is excluded when:
- Its type matches any entry in `EXCLUDE_TYPES` (exact match).
- Its mountpoint starts with any entry in `EXCLUDE_MOUNT` (prefix match).

Excluded filesystems are not shown in the output table.

---

## Logging

### Directory structure

```
scripts/
├── disk-usage-monitor.sh
├── disk-usage-monitor.status
├── disk-usage-monitor.email.state
├── disk-usage-monitor.lock
├── disk-usage-monitor.maintenance
└── logs/
    ├── disk-usage-monitor-error.log
    ├── disk-usage-monitor-error.log.2026-06-01_120000
    ├── disk-usage-monitor-execution.log
    └── disk-usage-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] threshold=80%
2026-06-20 10:00:01 RESULT all filesystems within threshold
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [app-prod-01] threshold=80%
2026-06-20 10:05:01 ALERT /
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [app-prod-01] threshold=80%
2026-06-20 10:10:01 RESULT all filesystems within threshold
2026-06-20 10:10:01 RECOVERY /
2026-06-20 10:10:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT /
2026-06-20 10:05:01 EMAIL sent to ops@example.com
2026-06-20 10:10:01 RECOVERY EMAIL sent for / to ops@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Archived copies older than the retention window are deleted.

Self-contained — no dependency on `logrotate`. If `find` is unavailable, rotation is silently skipped.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

## Integration

### Container usage (Kubernetes / Docker)

When running inside a container, set `HOSTNAME_LABEL` to a meaningful name
since the container hostname is typically an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

On read-only container filesystems, disable file-based state by pointing
state files to a writable volume or disabling them:

```bash
STATUS_FILE="/tmp/disk-usage-monitor.status"
STATE_FILE="/tmp/disk-usage-monitor.email.state"
LOG_DIR="/tmp/logs"
```

Or disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: disk-usage-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: disk-usage-monitor
            image: alpine/bash
            command: ["/scripts/disk-usage-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/disk-usage-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

### Checkmk (local check)

```bash
cp disk-usage-monitor.sh /usr/lib/check_mk_agent/local/disk-usage-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add Prometheus metrics inside `alert()`:

```bash
echo "disk_usage_above_threshold{host=\"${HOST_ID}\",mount=\"${detail}\"} 1" \
    >> /var/lib/node_exporter/disk-usage.prom
```

### systemd timer

```ini
# /etc/systemd/system/disk-usage-monitor.service
[Unit]
Description=Disk usage monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/disk-usage-monitor.sh
```

```ini
# /etc/systemd/system/disk-usage-monitor.timer
[Unit]
Description=Run disk usage monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now disk-usage-monitor.timer
```

---

## Use cases

### Standard server monitoring

```bash
THRESHOLD=85
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
EXCLUDE_TYPES="tmpfs devtmpfs squashfs overlay iso9660"
EXCLUDE_MOUNT="/run /sys /proc /dev"
```

### NFS and shared storage

When NFS or other network mounts report unreliable usage (or 0%), exclude them by prefix:

```bash
EXCLUDE_MOUNT="/mnt/nfs /mnt/cifs /mnt/smb"
```

### Tight threshold for small volumes

```bash
THRESHOLD=70
EMAIL_INTERVAL="1800"   # alert every 30 minutes while above threshold
```

### Multi-environment infrastructure

Maintain separate copies per environment:

```
/opt/scripts/
├── disk-usage-monitor-prod.sh      # THRESHOLD=85
├── disk-usage-monitor-staging.sh   # THRESHOLD=90
```

```cron
*/5 * * * * /opt/scripts/disk-usage-monitor-prod.sh    >/dev/null 2>&1
*/5 * * * * /opt/scripts/disk-usage-monitor-staging.sh >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD` | `80` | Alert when any filesystem exceeds this percentage. |
| `EXCLUDE_TYPES` | `tmpfs devtmpfs squashfs overlay iso9660` | Filesystem types to skip. |
| `EXCLUDE_MOUNT` | `""` *(none)* | Mountpoint prefixes to skip. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/disk-usage-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/disk-usage-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/disk-usage-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/disk-usage-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/disk-usage-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/disk-usage-monitor.status` | Tracks mountpoints currently in ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and current alert state, preview actions without performing them. |
| `--maintenance` | Toggle maintenance mode on/off. Alerts are suppressed while active. |
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