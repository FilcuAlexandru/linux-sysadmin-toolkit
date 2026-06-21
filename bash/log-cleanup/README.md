# log-cleanup.sh

Lightweight Bash script that deletes log files older than a configurable retention window from a target directory. Alerts on removal failures and sends a recovery email when cleanup succeeds again after a failure.

---

## Features

- **Glob-based file matching** — configurable pattern (default `*.log`) scoped to a target directory.
- **Configurable depth** — `MAX_DEPTH=1` (default, directory only) or `MAX_DEPTH=0` (unlimited, recursive).
- **Status tracking** — alerts once when cleanup fails (permission error, directory missing), stays silent while it keeps failing, and sends a recovery email when it succeeds again.
- **Separate meta-logs** — the script's own run logs (`LOG_DIR_META`) are kept separate from the directory being cleaned, so they are never accidentally deleted.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the full configuration, and lists exactly which files would be deleted.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — requires only Bash and `find`.

---

## Requirements

- **Bash 4.x+**
- **`find`** — required for file discovery and age filtering.

Optional (the script warns and continues without them):

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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/log-cleanup.sh \
     -o /opt/scripts/log-cleanup.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/log-cleanup.sh \
     -O /opt/scripts/log-cleanup.sh
```

### Manual copy

```bash
cp log-cleanup.sh /opt/scripts/log-cleanup.sh
chmod +x /opt/scripts/log-cleanup.sh
```

### Verify

```bash
/opt/scripts/log-cleanup.sh --version
/opt/scripts/log-cleanup.sh --dry-run
```

`--dry-run` is the recommended first step — it lists exactly which files would be deleted without touching anything.

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Cleanup

```bash
LOG_DIR="/path/to/logs"
PATTERN="*.log"
RETENTION_DAYS="30"
MAX_DEPTH="1"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `/path/to/logs` | Directory to clean. Must exist when the script runs. |
| `PATTERN` | `*.log` | Filename glob to match. Matched against filenames, not full paths. |
| `RETENTION_DAYS` | `30` | Delete files whose modification time is older than this many days. |
| `MAX_DEPTH` | `1` | How deep to search. `1` = directory only (no subdirectories). `0` = unlimited depth (recursive). |

#### Pattern examples

```bash
# Default: all .log files.
PATTERN="*.log"

# All .gz compressed logs.
PATTERN="*.log.gz"

# Specific prefix.
PATTERN="app-*.log"

# Multiple patterns require separate script copies or a loop.
```

#### Depth examples

```bash
# Default: only files directly in LOG_DIR.
MAX_DEPTH="1"

# Search all subdirectories recursively.
MAX_DEPTH="0"

# Search up to 2 levels deep.
MAX_DEPTH="2"
```

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/log-cleanup.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/log-cleanup.email.state` | Stores the timestamp of the last sent email. |

### Logging (meta-logs)

```bash
LOG_DIR_META="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR_META}/log-cleanup-error.log"
EXECUTION_LOG="${LOG_DIR_META}/log-cleanup-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR_META` | `<script_dir>/logs/` | Directory for the script's **own** run logs. Separate from `LOG_DIR`. |
| `ERROR_LOG` | `<LOG_DIR_META>/log-cleanup-error.log` | Alerts and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR_META>/log-cleanup-execution.log` | Every run (start, files removed, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Rotate and prune meta-logs older than this. `0` = keep forever. |

**Important:** `LOG_DIR_META` is deliberately separate from `LOG_DIR`. If both pointed to the same directory, the script could delete its own logs. Always keep them distinct.

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers:

```bash
HOSTNAME_LABEL="cleanup-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/log-cleanup.maintenance"
LOCK_FILE="${SCRIPT_DIR}/log-cleanup.lock"
STATUS_FILE="${SCRIPT_DIR}/log-cleanup.status"
```

These are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: log-cleanup.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Preview the deletions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./log-cleanup.sh
```

When files are found and deleted:

```
Removed: /var/log/myapp/app-2026-05-01.log
Removed: /var/log/myapp/app-2026-05-02.log
Removed: /var/log/myapp/app-2026-05-03.log
Removed 3 of 3 file(s) older than 30 days from /var/log/myapp.
```

When there is nothing to clean:

```
Nothing to clean in /var/log/myapp (pattern: *.log, older than 30 days)
```

### Dry-run

```bash
./log-cleanup.sh --dry-run
```

```
Prerequisites:
  find                         OK
  mail                         OK
  flock                        OK

Configuration:
  Host ID:                     cleanup-prod-01
  Log directory:               /var/log/myapp
  Pattern:                     *.log
  Retention:                   30 days
  Max depth:                   1
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/log-cleanup-error.log
  Execution log:               /opt/scripts/logs/log-cleanup-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

[dry-run] would delete 3 file(s) from /var/log/myapp:
  /var/log/myapp/app-2026-05-01.log
  /var/log/myapp/app-2026-05-02.log
  /var/log/myapp/app-2026-05-03.log
```

### Maintenance mode

```bash
./log-cleanup.sh --maintenance
# Output: Maintenance mode enabled

./log-cleanup.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### File discovery

The script uses `find` with these constraints:

```bash
find "$LOG_DIR" -maxdepth "$MAX_DEPTH" -type f -name "$PATTERN" -mtime +"$RETENTION_DAYS"
```

- `-type f` — only regular files; directories and symlinks are never deleted.
- `-name "$PATTERN"` — glob match against the filename only (not the full path).
- `-mtime +"$RETENTION_DAYS"` — files whose modification time is strictly older than the retention window.
- `-maxdepth` — omitted entirely when `MAX_DEPTH=0` (unlimited depth).

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              cleanup fails (first failure: dir missing or rm error)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              cleanup still failing (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              cleanup succeeds (or nothing to clean)
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

Both "directory not found" and "some files could not be removed" (permission errors) trigger the alert flow. "Nothing to clean" counts as success and triggers recovery if the previous run had failed.

### Partial failure handling

If some files are removed and others fail (e.g., mixed permissions), the script:
- Reports how many succeeded and how many failed.
- Triggers the alert flow for the failures.
- Does **not** count partial success as recovery — recovery requires a run with zero failures.

### Separate meta-log directory

`LOG_DIR_META` stores the script's own execution and error logs. This must be different from `LOG_DIR`. If they were the same directory, the cleanup could delete the script's own logs, and the PATTERN could accidentally match them.

---

## Logging

### Directory structure

```
scripts/
├── log-cleanup.sh
├── log-cleanup.status
├── log-cleanup.email.state
├── log-cleanup.lock
├── log-cleanup.maintenance
└── logs/                          ← LOG_DIR_META (script's own logs)
    ├── log-cleanup-error.log
    ├── log-cleanup-error.log.2026-06-01_120000
    ├── log-cleanup-execution.log
    └── log-cleanup-execution.log.2026-06-01_120000
```

```
/var/log/myapp/                    ← LOG_DIR (directory being cleaned)
├── app-2026-06-20.log             ← kept (within retention window)
├── app-2026-05-01.log             ← deleted (older than RETENTION_DAYS)
└── app-2026-05-02.log             ← deleted
```

### Execution log

```
2026-06-20 02:00:01 START [cleanup-prod-01] dir=/var/log/myapp pattern=*.log retention=30d
2026-06-20 02:00:01 REMOVED /var/log/myapp/app-2026-05-01.log
2026-06-20 02:00:01 REMOVED /var/log/myapp/app-2026-05-02.log
2026-06-20 02:00:01 RESULT removed=2 failed=0 total=2
2026-06-20 02:00:01 END
```

### Error log

```
2026-06-20 02:00:01 ALERT some files could not be removed from /var/log/myapp
2026-06-20 02:00:01 EMAIL sent to ops@example.com
2026-06-20 03:00:01 RECOVERY EMAIL sent to ops@example.com
```

### Log rotation

At every run, the script checks each meta-log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Archived copies older than the retention window are deleted. Self-contained — no dependency on `logrotate`.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of meta-logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; meta-logs grow indefinitely. |

---

## Integration

### Cron

```cron
0 2 * * * /opt/scripts/log-cleanup.sh >/dev/null 2>&1
```

Runs daily at 02:00. All configuration lives in the script.

### Checkmk (local check)

```bash
cp log-cleanup.sh /usr/lib/check_mk_agent/local/log-cleanup.sh
```

### Grafana / Prometheus (textfile collector)

```bash
echo "log_cleanup_removed_total{host=\"${HOST_ID}\",dir=\"${LOG_DIR}\"} ${removed}" \
    > /var/lib/node_exporter/log-cleanup.prom
```

### systemd timer

```ini
# /etc/systemd/system/log-cleanup.service
[Unit]
Description=Log file cleanup

[Service]
Type=oneshot
ExecStart=/opt/scripts/log-cleanup.sh
```

```ini
# /etc/systemd/system/log-cleanup.timer
[Unit]
Description=Run log cleanup daily at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now log-cleanup.timer
```

---

## Use cases

### Application log rotation

```bash
LOG_DIR="/var/log/myapp"
PATTERN="*.log"
RETENTION_DAYS="30"
ALERT_EMAIL="ops@company.com"
```

### Compressed archive cleanup

```bash
LOG_DIR="/var/log/myapp"
PATTERN="*.log.gz"
RETENTION_DAYS="90"
```

### Recursive cleanup of a deep log tree

```bash
LOG_DIR="/var/log/services"
PATTERN="*.log"
RETENTION_DAYS="14"
MAX_DEPTH="0"   # search all subdirectories
```

### Multiple directories

Maintain separate script copies per directory:

```
/opt/scripts/
├── cleanup-applog.sh    # LOG_DIR=/var/log/myapp, RETENTION_DAYS=30
├── cleanup-nginx.sh     # LOG_DIR=/var/log/nginx, RETENTION_DAYS=14
├── cleanup-audit.sh     # LOG_DIR=/var/log/audit, RETENTION_DAYS=90
```

```cron
0 2 * * * /opt/scripts/cleanup-applog.sh  >/dev/null 2>&1
0 3 * * * /opt/scripts/cleanup-nginx.sh   >/dev/null 2>&1
0 4 * * * /opt/scripts/cleanup-audit.sh   >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `/path/to/logs` | Directory to clean. |
| `PATTERN` | `*.log` | Filename glob to match. |
| `RETENTION_DAYS` | `30` | Delete files older than this many days. |
| `MAX_DEPTH` | `1` | Search depth. `1` = top-level only, `0` = unlimited. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/log-cleanup.email.state` | Last-email timestamp file. |
| `LOG_DIR_META` | `<script_dir>/logs/` | Directory for the script's own run logs. |
| `ERROR_LOG` | `<LOG_DIR_META>/log-cleanup-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR_META>/log-cleanup-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep meta-logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/log-cleanup.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/log-cleanup.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/log-cleanup.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, and list files that would be deleted — without deleting anything. |
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