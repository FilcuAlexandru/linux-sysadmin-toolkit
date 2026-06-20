# directory-backup.sh

Lightweight Bash script that creates a timestamped `.tar.gz` backup of a directory, prunes archives older than a configurable retention window, and alerts when a backup fails. Sends a recovery email when backups start succeeding again after a failure.

---

## Features

- **Timestamped archives** — archive names include date and time (`backup_2026-06-20_120000.tar.gz`), so multiple runs per day never overwrite each other.
- **Automatic retention pruning** — archives older than `RETENTION_DAYS` are deleted at the end of every successful run.
- **Status tracking** — alerts once when a backup fails, stays silent while it keeps failing, and sends a recovery email when it succeeds again.
- **Failure detection at two levels** — catches both missing source directories and `tar` failures.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency, the full configuration, and what would be created or pruned.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **`tar`** — required for creating archives (present on virtually all Linux systems).

Optional (the script warns and continues without them):

- **`find`** — needed for retention pruning and log rotation.
- **`du`** — used to show the archive size after creation.
- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for instance locking (`util-linux`).

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/directory-backup.sh \
     -o /opt/scripts/directory-backup.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/directory-backup.sh \
     -O /opt/scripts/directory-backup.sh
```

### Manual copy

```bash
cp directory-backup.sh /opt/scripts/directory-backup.sh
chmod +x /opt/scripts/directory-backup.sh
```

### Verify

```bash
/opt/scripts/directory-backup.sh --version
/opt/scripts/directory-backup.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Backup

```bash
SOURCE="/path/to/directory"
BACKUP_DIR="/var/backups"
RETENTION_DAYS="7"
```

| Variable | Default | Description |
|---|---|---|
| `SOURCE` | `/path/to/directory` | Directory to back up. Must exist and be readable. |
| `BACKUP_DIR` | `/var/backups` | Where archives are stored. Created automatically if missing. |
| `RETENTION_DAYS` | `7` | Archives older than this are deleted after a successful backup. |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/directory-backup.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/directory-backup.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com backup@example.com manager@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/directory-backup-error.log"
EXECUTION_LOG="${LOG_DIR}/directory-backup-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/directory-backup-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/directory-backup-execution.log` | Every run (start, result, end). `""` = disabled. |
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
HOSTNAME_LABEL="backup-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable → `hostname` command → `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/directory-backup.maintenance"
LOCK_FILE="${SCRIPT_DIR}/directory-backup.lock"
STATUS_FILE="${SCRIPT_DIR}/directory-backup.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: directory-backup.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./directory-backup.sh
```

```
Backup created: /var/backups/backup_2026-06-20_080000.tar.gz (42M)
Removed archives older than 7 days:
/var/backups/backup_2026-06-12_080000.tar.gz
```

### Dry-run

```bash
./directory-backup.sh --dry-run
```

```
Prerequisites:
  tar                          OK
  find                         OK
  du                           OK
  mail                         OK
  flock                        OK

Configuration:
  Host ID:                     backup-prod-01
  Source:                      /opt/app/data
  Backup dir:                  /mnt/backups
  Retention:                   7 days
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/directory-backup-error.log
  Execution log:               /opt/scripts/logs/directory-backup-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

[dry-run] would archive '/opt/app/data' -> /mnt/backups/backup_2026-06-20_080000.tar.gz
[dry-run] would delete archives older than 7 days:
/mnt/backups/backup_2026-06-12_080000.tar.gz
```

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./directory-backup.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./directory-backup.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              backup fails (first failure)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              backup still failing (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              backup succeeds
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Failure detection

The script catches failures at two levels:

1. **Source directory missing** — checked before the backup runs; triggers the status/alert flow immediately.
2. **`tar` failure** — caught when `tar -czf` exits non-zero (disk full, permission error, etc.); same status/alert flow.

Both levels use the same status tracking, so you always get exactly one alert email per failure event regardless of what caused it.

### Retention pruning

After a successful backup, `find` removes archives matching `backup_*.tar.gz` in `BACKUP_DIR` that are older than `RETENTION_DAYS`. The glob scope is deliberately narrow — it only touches archives created by this script, not other files in the same directory.

Pruning only runs on **success**, not on failure, so a failing backup does not cause previously good archives to be deleted.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next alert (when transitioning from OK to ALERT), the script checks whether `EMAIL_INTERVAL` seconds have passed. This is a safety net; status tracking is the primary deduplication mechanism.

Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── directory-backup.sh
├── directory-backup.status
├── directory-backup.email.state
├── directory-backup.lock
├── directory-backup.maintenance
└── logs/
    ├── directory-backup-error.log
    ├── directory-backup-error.log.2026-06-01_120000
    ├── directory-backup-execution.log
    └── directory-backup-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 08:00:01 START [backup-prod-01] source=/opt/app/data
2026-06-20 08:00:08 RESULT backup created: /mnt/backups/backup_2026-06-20_080001.tar.gz (42M)
2026-06-20 08:00:08 PRUNED 1 archive(s)
2026-06-20 08:00:08 END
```

On failure:

```
2026-06-20 08:00:01 START [backup-prod-01] source=/opt/app/data
2026-06-20 08:00:01 RESULT source not found: /opt/app/data
2026-06-20 08:00:02 START [backup-prod-01] source=/opt/app/data
2026-06-20 08:00:02 RESULT source not found: /opt/app/data
2026-06-20 08:00:02 Already in ALERT state
```

### Error log

```
2026-06-20 08:00:01 ALERT source directory not found: /opt/app/data
2026-06-20 08:00:01 EMAIL sent to ops@example.com
2026-06-20 09:15:00 RECOVERY EMAIL sent to ops@example.com
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

### Cron

```cron
0 2 * * * /opt/scripts/directory-backup.sh >/dev/null 2>&1
```

Runs daily at 02:00. All configuration lives in the script.

### Pre-check for another backup tool

Use as a pre-flight check before a more complex backup process:

```bash
if ! /opt/scripts/directory-backup.sh >/dev/null 2>&1; then
    echo "Backup pre-check failed" >&2
    exit 1
fi
```

### Checkmk (local check)

```bash
cp directory-backup.sh /usr/lib/check_mk_agent/local/directory-backup.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "backup_last_success_timestamp{host=\"${HOST_ID}\",source=\"${SOURCE}\"} $(date +%s)" \
    > /var/lib/node_exporter/directory-backup.prom
```

### systemd timer

```ini
# /etc/systemd/system/directory-backup.service
[Unit]
Description=Directory backup

[Service]
Type=oneshot
ExecStart=/opt/scripts/directory-backup.sh
```

```ini
# /etc/systemd/system/directory-backup.timer
[Unit]
Description=Run directory backup daily at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now directory-backup.timer
```

---

## Use cases

### Application data backup

```bash
SOURCE="/opt/app/data"
BACKUP_DIR="/mnt/nfs-backups/app"
RETENTION_DAYS="14"
ALERT_EMAIL="ops@company.com devops@company.com"
```

### Configuration backup

```bash
SOURCE="/etc"
BACKUP_DIR="/var/backups/etc"
RETENTION_DAYS="30"
ALERT_EMAIL="infra@company.com"
```

### Multi-directory backups

Maintain separate copies of the script for each directory:

```
/opt/scripts/
├── backup-appdata.sh      # SOURCE=/opt/app/data
├── backup-config.sh       # SOURCE=/etc
├── backup-webroot.sh      # SOURCE=/var/www
```

```cron
0 2 * * * /opt/scripts/backup-appdata.sh  >/dev/null 2>&1
0 3 * * * /opt/scripts/backup-config.sh   >/dev/null 2>&1
0 4 * * * /opt/scripts/backup-webroot.sh  >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `SOURCE` | `/path/to/directory` | Directory to back up. |
| `BACKUP_DIR` | `/var/backups` | Where archives are stored. |
| `RETENTION_DAYS` | `7` | Days to keep archives. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/directory-backup.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/directory-backup-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/directory-backup-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/directory-backup.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/directory-backup.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/directory-backup.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview the archive name and what would be pruned — without performing anything. |
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