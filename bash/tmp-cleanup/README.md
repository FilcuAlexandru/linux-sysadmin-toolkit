# tmp-cleanup.sh

Lightweight Bash script that deletes files older than a configurable age from a directory and prunes any empty subdirectories left behind. Designed for servers where application temp directories, job output folders, or upload staging areas accumulate stale files and need periodic cleanup.

Sends email alerts (rate-limited) when files cannot be deleted, so failures in cron never go unnoticed.

---

## Features

- **Age-based file removal** — deletes files not modified in more than `AGE_DAYS` days using `find(1)`.
- **Empty directory pruning** — removes subdirectories that are left empty after file deletion.
- **Per-file logging** — every deleted file is recorded in the execution log with a timestamp.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)` when deletions fail, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Maintenance mode** — toggle alert suppression for planned downtime with `--maintenance`. State persists across runs.
- **Structured logging** — optional execution log (every run) and error log (only failures), with automatic rotation and retention-based pruning.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images, no hard dependencies beyond Bash and `find`.
- **Dry-run mode** — check prerequisites and preview all deletions without removing anything.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies.

---

## Requirements

- **Bash 4.x+** (present on virtually all modern Linux systems and most container base images).
- **`find` command** (required for file discovery and empty directory pruning; present on all Linux systems).
- **`mail` command** (optional; only needed for email alerts).
- **A configured MTA/relay** (optional; only needed for email delivery).
- **`flock` command** (optional; only needed to prevent overlapping cron runs. If missing, locking is silently skipped).

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/tmp-cleanup.sh \
     -o /opt/scripts/tmp-cleanup.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/tmp-cleanup.sh \
     -O /opt/scripts/tmp-cleanup.sh
```

### Manual copy

```bash
cp tmp-cleanup.sh /opt/scripts/tmp-cleanup.sh
```

### Make executable and verify

```bash
chmod +x /opt/scripts/tmp-cleanup.sh
/opt/scripts/tmp-cleanup.sh --version
/opt/scripts/tmp-cleanup.sh --help
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Cleanup target

```bash
TMP_DIR="/tmp"
AGE_DAYS="7"
```

| Variable | Default | Description |
|---|---|---|
| `TMP_DIR` | `/tmp` | Directory to clean. Must exist. |
| `AGE_DAYS` | `7` | Delete files not modified in more than this many days. Set to `1` to delete files older than 24 hours. |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/tmp-cleanup.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. Can also be set via environment. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/tmp-cleanup.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com dev@example.com manager@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/tmp-cleanup-error.log"
EXECUTION_LOG="${LOG_DIR}/tmp-cleanup-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/tmp-cleanup-error.log` | Failed deletions and alerts. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/tmp-cleanup-execution.log` | Every run and every deleted file. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

Logging is fully optional. If the log directory cannot be created or a file cannot be written, the script prints a warning and continues.

To disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

### Host identification

```bash
HOSTNAME_LABEL=""
```

| Variable | Default | Description |
|---|---|---|
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom name used in alerts, emails, and logs. When empty, the system hostname is used. |

Useful in containers where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="worker-prod-01"
```

---

## Usage

```
Usage: tmp-cleanup.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview deletions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./tmp-cleanup.sh
```

```
Removed 42 file(s) older than 7 days from /tmp; pruned empty subdirectories.
```

### Dry-run

Prints a full prerequisites report (tools available, active configuration, current state) and lists every file that would be deleted — without removing anything.

```bash
./tmp-cleanup.sh --dry-run
```

```
Prerequisites:
  find                         OK
  mail                         MISSING (email will not work)
  flock                        OK

Configuration:
  Host ID:                     app-prod-01
  Directory:                   /tmp
  Max file age:                7 days
  E-Mail:                      DISABLED
  Error log:                   /opt/scripts/logs/tmp-cleanup-error.log
  Execution log:               /opt/scripts/logs/tmp-cleanup-execution.log
  Log retention:               14 days

State:
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

[dry-run] would delete 42 file(s) from /tmp:
  /tmp/upload-staging/job-1234.tmp
  /tmp/upload-staging/job-1235.tmp
  ...
[dry-run] would then prune empty subdirectories
```

### Maintenance mode

Toggle alert suppression for planned downtime. The state persists across runs until toggled off.

```bash
# Enable maintenance mode (alerts suppressed).
./tmp-cleanup.sh --maintenance
# Maintenance mode enabled

# Disable maintenance mode (alerts resume).
./tmp-cleanup.sh --maintenance
# Maintenance mode disabled
```

While maintenance mode is active, the script still cleans files and logs — only alerting (console and email) is suppressed.

---

## How it works

### Cleanup flow

```
Find files in TMP_DIR older than AGE_DAYS
    │
    ├── None found ──── Log "nothing to delete" ──── Exit
    │
    └── Files found
            │
            ├── For each file: rm -f
            │       ├── Success ──── removed++ ── Log "DELETED /path"
            │       └── Failure ──── failed++  ── Log "FAILED /path"
            │
            ├── Prune empty subdirectories (find -empty -delete)
            │
            ├── Print summary (removed N file(s), pruned empty dirs)
            │
            └── failed > 0 ?
                    ├── No  ──── Exit cleanly
                    └── Yes ──── alert() ──── Console + email (rate-limited)
```

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each email. On the next failure, the script checks whether `EMAIL_INTERVAL` seconds have passed. If not, the email is skipped. Console alerts are never rate-limited.

If the state file is missing, empty, or corrupt, the script treats it as "never sent" and allows the email.

---

## Logging

### Directory structure

```
scripts/
├── tmp-cleanup.sh
└── logs/
    ├── tmp-cleanup-error.log                         ← active
    ├── tmp-cleanup-error.log.2026-06-01_120000       ← rotated archive
    ├── tmp-cleanup-execution.log                     ← active
    └── tmp-cleanup-execution.log.2026-06-01_120000   ← rotated archive
```

### Execution log

```
2026-06-20 03:00:01 START [app-prod-01] cleaning /tmp (files older than 7 days)
2026-06-20 03:00:01 DELETED /tmp/upload-staging/job-1234.tmp
2026-06-20 03:00:01 DELETED /tmp/upload-staging/job-1235.tmp
2026-06-20 03:00:01 RESULT removed=42 failed=0
2026-06-20 03:00:01 END
```

Every deleted file is recorded individually. The `[hostname]` tag identifies the source when logs from multiple hosts are aggregated.

### Error log

```
2026-06-20 03:00:01 FAILED to delete /tmp/locked-file.tmp
2026-06-20 03:00:01 ALERT could not delete 1 file(s) from /tmp (removed 41 successfully)
2026-06-20 03:00:01 EMAIL sent to ops@example.com
```

### Log rotation

At every run, the script checks each log file:

1. If older than `LOG_RETENTION_DAYS`, rename with a timestamp suffix and start fresh.
2. Delete archived copies older than `LOG_RETENTION_DAYS`.

Self-contained — no dependency on `logrotate`. If `find` is not available (minimal containers), rotation is silently skipped and logs continue to append.

| `LOG_RETENTION_DAYS` | Behavior |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

## State files

The script maintains state files next to itself (all paths are configurable):

| File | Variable | Purpose |
|---|---|---|
| `tmp-cleanup.email.state` | `STATE_FILE` | Unix timestamp of the last sent email. Used for rate-limiting. |
| `tmp-cleanup.maintenance` | `MAINTENANCE_FILE` | Presence of this file activates maintenance mode. Created/removed by `--maintenance`. |
| `tmp-cleanup.lock` | `LOCK_FILE` | `flock(1)` lock file. Prevents overlapping cron runs. |

All state files are best-effort: if they cannot be created or read (e.g. read-only filesystem), the script degrades gracefully and continues.

---

## Integration

### Cron

Edit the script to configure all settings, then add a clean cron entry:

```cron
# Run daily at 03:00.
0 3 * * * /opt/scripts/tmp-cleanup.sh >/dev/null 2>&1
```

To capture output in syslog:

```cron
0 3 * * * /opt/scripts/tmp-cleanup.sh 2>&1 | logger -t tmp-cleanup
```

### Pre-job check (abort if cleanup fails)

```bash
if ! /opt/scripts/tmp-cleanup.sh >/dev/null 2>&1; then
    echo "Cleanup failed; aborting job" >&2
    exit 1
fi
```

### Checkmk (local check)

Place the script in the Checkmk local checks directory:

```bash
cp tmp-cleanup.sh /usr/lib/check_mk_agent/local/tmp-cleanup.sh
```

Adapt the `alert()` function body for Checkmk-compatible output. The function is designed as a seam for this purpose.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "tmp_cleanup_failed_deletions{host=\"${HOST_ID}\",dir=\"${TMP_DIR}\"} ${failed}" \
    > /var/lib/node_exporter/tmp-cleanup.prom
```

### systemd timer

```ini
# /etc/systemd/system/tmp-cleanup.service
[Unit]
Description=Temp directory cleanup

[Service]
Type=oneshot
ExecStart=/opt/scripts/tmp-cleanup.sh
```

```ini
# /etc/systemd/system/tmp-cleanup.timer
[Unit]
Description=Run temp cleanup daily at 03:00

[Timer]
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now tmp-cleanup.timer
```

---

## Use cases

### Application upload staging directory

```bash
TMP_DIR="/var/app/uploads/staging"
AGE_DAYS="1"
ALERT_EMAIL="ops@company.com"
```

### WebLogic server temp files

```bash
TMP_DIR="/opt/oracle/middleware/user_projects/domains/base_domain/servers/AdminServer/tmp"
AGE_DAYS="3"
ALERT_EMAIL="ops@company.com"
EMAIL_INTERVAL="3600"
```

### Multiple directories (separate script copies)

```
/opt/scripts/
├── tmp-cleanup-uploads.sh    # TMP_DIR=/var/app/uploads, AGE_DAYS=1
├── tmp-cleanup-jobs.sh       # TMP_DIR=/var/app/jobs/output, AGE_DAYS=7
└── tmp-cleanup-reports.sh    # TMP_DIR=/var/app/reports/tmp, AGE_DAYS=30
```

```cron
0 2 * * * /opt/scripts/tmp-cleanup-uploads.sh  >/dev/null 2>&1
0 3 * * * /opt/scripts/tmp-cleanup-jobs.sh     >/dev/null 2>&1
0 4 * * * /opt/scripts/tmp-cleanup-reports.sh  >/dev/null 2>&1
```

### Container with read-only root filesystem

```bash
TMP_DIR="/mnt/tmp"
AGE_DAYS="1"
HOSTNAME_LABEL="worker-prod-01"
ERROR_LOG=""
EXECUTION_LOG=""
```

---

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Preview the deletions without performing them. |
| `--maintenance` | Toggle maintenance mode on/off. Alerts are suppressed while active. |
| `--version` | Print version and exit. |
| `--help` | Print usage information and exit. |


---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. |

## Configuration reference

All variables are set inside the script.

| Variable | Default | Description |
|---|---|---|
| `TMP_DIR` | `/tmp` | Directory to clean. |
| `AGE_DAYS` | `7` | Delete files older than this many days. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between emails. |
| `STATE_FILE` | `<script_dir>/tmp-cleanup.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/tmp-cleanup-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/tmp-cleanup-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts/logs. |
| `MAINTENANCE_FILE` | `<script_dir>/tmp-cleanup.maintenance` | Maintenance mode marker (auto-managed). |

---

## Author

**Filcu Alexandru**

---

## License

This script is provided as-is for personal and professional use.