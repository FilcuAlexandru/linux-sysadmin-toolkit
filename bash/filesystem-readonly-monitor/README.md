# filesystem-readonly-monitor.sh

Detect real filesystems that have been remounted read-only.

---

## Features

- Detects the kernel's error-triggered read-only remounts early.
- Auto-scan mode covers all real disk filesystems (ext*/xfs/btrfs/…).
- Watch mode enforces that specific mount points stay read-write.
- Status-aware alerting with recovery email and rate-limiting.
- Maintenance mode, locking, structured logging with rotation.
- **Status tracking** — alerts once when a problem appears, stays silent while it persists, and sends a recovery email when it clears.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with a graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency, the full configuration, and the current runtime state before previewing actions.
- **Monitoring integration** — the `alert()` function is a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels and graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux** with the `/proc` (and, where noted, `/sys`) filesystem.

Dependencies (the script warns and continues without the optional ones):

- `/proc/mounts` — required (standard on Linux)
- `awk` — used in alert email
- `mail` / `flock` / `find` — optional

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-sysadmin-toolkit.git
cd linux-sysadmin-toolkit/bash/filesystem-readonly-monitor

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-sysadmin-toolkit/main/bash/filesystem-readonly-monitor/filesystem-readonly-monitor.sh \
     -o /opt/scripts/filesystem-readonly-monitor.sh
```

### Manual copy

```bash
cp filesystem-readonly-monitor.sh /opt/scripts/filesystem-readonly-monitor.sh
chmod +x /opt/scripts/filesystem-readonly-monitor.sh
```

### Verify

```bash
/opt/scripts/filesystem-readonly-monitor.sh --version
/opt/scripts/filesystem-readonly-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives
below a clearly marked separator line (`no changes needed past this line`) — you never need to edit
anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script
once; cron entries stay clean.

### Script settings

```bash
WATCH=""
```

| Variable | Default | Description |
|---|---|---|
| `WATCH` | `"" (all)` | Mount points that must be read-write; empty scans all real filesystems. |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/filesystem-readonly-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/filesystem-readonly-monitor.email.state` | Stores the timestamp of the last sent email. |

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/filesystem-readonly-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/filesystem-readonly-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/filesystem-readonly-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/filesystem-readonly-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable -> `hostname` command -> `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/filesystem-readonly-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/filesystem-readonly-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/filesystem-readonly-monitor.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: filesystem-readonly-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./filesystem-readonly-monitor.sh
```

### Dry-run

```bash
./filesystem-readonly-monitor.sh --dry-run
```

```
Prerequisites:
  awk                          OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Privileges:                  root
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/filesystem-readonly-monitor-error.log
  Execution log:               /opt/scripts/logs/filesystem-readonly-monitor-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK
```

The dry-run lists every dependency (OK / MISSING), the active configuration and privilege level, and
the current runtime state, then previews the alert that *would* fire — without sending anything or
changing state.

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./filesystem-readonly-monitor.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./filesystem-readonly-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

The script parses `/proc/mounts`. In auto mode it inspects every real disk filesystem; in watch mode it verifies each listed mount point is present and read-write. Any read-only (or missing watched) mount raises an alert.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
                 condition detected (first time)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
                 condition persists (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
                 condition clears
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Instance locking

Uses `flock(1)` to prevent overlapping runs. If another instance holds the lock, the new one exits
silently with code 0 so cron does not report an error. Skipped gracefully when `flock` is unavailable
or the lock file cannot be created (read-only filesystem).

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next OK→ALERT transition, the
script checks whether `EMAIL_INTERVAL` seconds have passed. This is a safety net; the status tracking
above is the primary deduplication mechanism. Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── filesystem-readonly-monitor.sh
├── filesystem-readonly-monitor.status
├── filesystem-readonly-monitor.email.state
├── filesystem-readonly-monitor.lock
├── filesystem-readonly-monitor.maintenance
└── logs/
    ├── filesystem-readonly-monitor-error.log
    ├── filesystem-readonly-monitor-error.log.2026-06-01_120000
    ├── filesystem-readonly-monitor-execution.log
    └── filesystem-readonly-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 08:00:01 START [app-prod-01]
2026-06-20 08:00:01 RESULT ... (ok)
2026-06-20 08:00:01 END
```

### Error log

```
2026-06-20 08:00:01 ALERT ...
2026-06-20 08:00:01 EMAIL sent to ops@example.com
2026-06-20 09:15:00 RECOVERY EMAIL sent to ops@example.com
```

### Log rotation

At every run, each log older than `LOG_RETENTION_DAYS` is renamed with a timestamp suffix and a fresh
log is started; archived copies past the window are deleted. Self-contained — no dependency on
`logrotate`. If `find` is unavailable, rotation is silently skipped.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

## Integration

### Container usage (Kubernetes / Docker)

Set `HOSTNAME_LABEL` to a meaningful name, and on read-only filesystems point state files at a
writable volume:

```bash
HOSTNAME_LABEL="app-prod-01"
STATUS_FILE="/tmp/filesystem-readonly-monitor.status"
STATE_FILE="/tmp/filesystem-readonly-monitor.email.state"
LOG_DIR="/tmp/logs"
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: filesystem-readonly-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: filesystem-readonly-monitor
            image: alpine/bash
            command: ["/scripts/filesystem-readonly-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```

### Cron

```cron
*/5 * * * * /opt/scripts/filesystem-readonly-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

### systemd timer

```ini
# /etc/systemd/system/filesystem-readonly-monitor.service
[Unit]
Description=filesystem-readonly-monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/filesystem-readonly-monitor.sh
```

```ini
# /etc/systemd/system/filesystem-readonly-monitor.timer
[Unit]
Description=Run filesystem-readonly-monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now filesystem-readonly-monitor.timer
```

### Checkmk (local check)

```bash
cp filesystem-readonly-monitor.sh /usr/lib/check_mk_agent/local/filesystem-readonly-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Emit a Prometheus metric from inside `alert()`:

```bash
echo "filesystem_readonly_monitor_alert{host=\"${HOST_ID}\"} 1" \
    > /var/lib/node_exporter/filesystem-readonly-monitor.prom
```

---

## Use cases

### Scheduled monitoring with email alerts

```bash
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
HOSTNAME_LABEL="app-prod-01"
```

Run every few minutes from cron; the on-call team gets one email when the problem starts and one when
it recovers.

### Container / sidecar check

```bash
HOSTNAME_LABEL="k8s-worker-prod-03"
ERROR_LOG=""
EXECUTION_LOG=""
```

Logging disabled for container environments where stdout/stderr is captured by the runtime.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `WATCH` | `"" (all)` | Mount points that must be read-write; empty scans all real filesystems. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/filesystem-readonly-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory (auto-created). |
| `ERROR_LOG` | `<LOG_DIR>/filesystem-readonly-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/filesystem-readonly-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs; `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/filesystem-readonly-monitor.maintenance` | Maintenance marker. |
| `LOCK_FILE` | `<script_dir>/filesystem-readonly-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/filesystem-readonly-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview the action — without performing anything. |
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
