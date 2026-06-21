# memory-usage-monitor.sh

Lightweight Bash script that monitors memory usage and alerts when it exceeds a configurable threshold. Reads directly from `/proc/meminfo` for accurate, locale-independent measurements with no external binary required. Includes the top 5 memory-consuming processes (by RSS) in every alert email so you know immediately what is causing the pressure.

---

## Features

- **Kernel-first measurement** — reads `/proc/meminfo` (`MemTotal - MemAvailable`) for accurate memory usage; falls back to `free -m` if `/proc/meminfo` is unavailable.
- **Accurate used-memory calculation** — uses `MemAvailable` rather than the `used` column from `free`, which excludes reclaimable kernel cache and buffers.
- **Top 5 processes in email** — every alert email includes a ranked list of the five most memory-intensive processes (RSS in MB) at the time of the alert.
- **Status tracking** — alerts once when memory goes above the threshold, stays silent while it remains high, and sends a recovery email when it drops back below.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency and the current runtime state before previewing actions.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux kernel with `/proc` mounted** (standard on all distributions and containers)

Optional (the script warns and continues without them):

- **`free`** — fallback memory source when `/proc/meminfo` is unavailable.
- **`ps`** — needed for the top 5 process list in alert emails.
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/memory-usage-monitor.sh \
     -o /opt/scripts/memory-usage-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/memory-usage-monitor.sh \
     -O /opt/scripts/memory-usage-monitor.sh
```

### Manual copy

```bash
cp memory-usage-monitor.sh /opt/scripts/memory-usage-monitor.sh
chmod +x /opt/scripts/memory-usage-monitor.sh
```

### Verify

```bash
/opt/scripts/memory-usage-monitor.sh --version
/opt/scripts/memory-usage-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Threshold

```bash
THRESHOLD=80
```

Alert fires when used memory (excluding kernel cache and buffers) exceeds this percentage. Set between `0` and `100`.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/memory-usage-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/memory-usage-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com infra@example.com manager@example.com"
```

All listed addresses receive the same alert and recovery emails.

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/memory-usage-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/memory-usage-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/memory-usage-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/memory-usage-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
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
HOSTNAME_LABEL="app-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable → `hostname` command → `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/memory-usage-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/memory-usage-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/memory-usage-monitor.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: memory-usage-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./memory-usage-monitor.sh
```

Output when below threshold:

```
Memory Usage: 2.14/15.62GB (13.70%)
```

Output when above threshold:

```
Memory Usage: 13.24/15.62GB (84.76%)
ALERT: Memory usage above 80% on app-prod-01: 84.76% (13.24/15.62GB)
```

### Dry-run

```bash
./memory-usage-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/meminfo                OK
  free                         OK
  ps                           OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Threshold:                   80%
  E-Mail:                      ops@example.com infra@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/memory-usage-monitor-error.log
  Execution log:               /opt/scripts/logs/memory-usage-monitor-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

Memory Usage: 13.24/15.62GB (84.76%)
[dry-run] would raise alert: 84.76% (13.24/15.62GB)
[dry-run] top 5 processes that would be included in email:
  1234       4823.5MB  java
  5678        512.3MB  postgres
  9012        234.1MB  python3
  3456        128.7MB  nginx
  7890         64.2MB  redis-server
[dry-run] would email: ops@example.com infra@example.com (last sent: never)
```

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./memory-usage-monitor.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./memory-usage-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Memory measurement (source priority)

1. **`/proc/meminfo`** (preferred) — reads `MemTotal` and `MemAvailable` directly from the kernel. No external binary needed. Available on every Linux system and inside every standard container. The formula:

   ```
   used = MemTotal - MemAvailable
   pct  = used / MemTotal * 100
   ```

   `MemAvailable` is the kernel's estimate of memory available for new processes, accounting for reclaimable cache and buffers. This gives the most accurate picture of actual memory pressure.

2. **`free -m`** (fallback) — used only when `/proc/meminfo` is not readable. Converts MB values to GB in `awk`. Less accurate on some systems because `free`'s `used` column calculation varies between versions.

### Why `MemAvailable` instead of `MemUsed`

`/proc/meminfo` also has a `MemFree` field, but it only counts completely unused memory. The kernel keeps a large portion of RAM as file cache — technically "used" but immediately reclaimable when a process needs it. `MemAvailable` already accounts for this, making it the correct field for alerting on actual memory pressure.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              memory > THRESHOLD (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    │ + top 5 RSS │
                    └──────┬──────┘
                           │
              memory still > THRESHOLD (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              memory <= THRESHOLD
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Email body

Every alert email includes a formatted table of the five most memory-intensive processes at the moment the alert fires:

```
Memory usage above 80% on app-prod-01: 84.76% (13.24/15.62GB)

Top 5 memory-consuming processes:
  1234       4823.5MB  java
  5678        512.3MB  postgres
  9012        234.1MB  python3
  3456        128.7MB  nginx
  7890         64.2MB  redis-server
```

Columns: PID, RSS in MB (Resident Set Size — physical memory actually in use), process name. Collected via `ps -eo pid,rss,comm --sort=-rss`. If `ps` is not available, the section shows `(ps not available)` and the email is still sent.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next alert (when transitioning from OK to ALERT), the script checks whether `EMAIL_INTERVAL` seconds have passed. Status tracking is the primary deduplication mechanism; rate-limiting is a safety net.

Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── memory-usage-monitor.sh
├── memory-usage-monitor.status
├── memory-usage-monitor.email.state
├── memory-usage-monitor.lock
├── memory-usage-monitor.maintenance
└── logs/
    ├── memory-usage-monitor-error.log
    ├── memory-usage-monitor-error.log.2026-06-01_120000
    ├── memory-usage-monitor-execution.log
    └── memory-usage-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] threshold=80%
2026-06-20 10:00:01 RESULT 13.70% used=2.14GB total=15.62GB (ok)
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [app-prod-01] threshold=80%
2026-06-20 10:05:01 RESULT 84.76% used=13.24GB total=15.62GB (above threshold)
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [app-prod-01] threshold=80%
2026-06-20 10:10:01 RESULT 85.12% used=13.30GB total=15.62GB (above threshold)
2026-06-20 10:10:01 Already in ALERT state
2026-06-20 10:10:01 END
2026-06-20 10:45:01 START [app-prod-01] threshold=80%
2026-06-20 10:45:01 RESULT 14.23% used=2.22GB total=15.62GB (ok)
2026-06-20 10:45:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT 84.76% (13.24/15.62GB)
2026-06-20 10:05:01 EMAIL sent to ops@example.com infra@example.com
2026-06-20 10:45:01 RECOVERY EMAIL sent to ops@example.com infra@example.com
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
STATUS_FILE="/tmp/memory-usage-monitor.status"
STATE_FILE="/tmp/memory-usage-monitor.email.state"
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
  name: memory-usage-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: memory-usage-monitor
            image: alpine/bash
            command: ["/scripts/memory-usage-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/memory-usage-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

### Checkmk (local check)

```bash
cp memory-usage-monitor.sh /usr/lib/check_mk_agent/local/memory-usage-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "memory_usage_percent{host=\"${HOST_ID}\"} ${pct}" \
    > /var/lib/node_exporter/memory-usage.prom
```

### systemd timer

```ini
# /etc/systemd/system/memory-usage-monitor.service
[Unit]
Description=Memory usage monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/memory-usage-monitor.sh
```

```ini
# /etc/systemd/system/memory-usage-monitor.timer
[Unit]
Description=Run memory usage monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now memory-usage-monitor.timer
```

---

## Use cases

### High-memory alert with process identification

The primary use case: know immediately which process caused the spike without having to SSH in.

```bash
THRESHOLD=80
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
HOSTNAME_LABEL="db-prod-01"
```

An alert email at 03:00 includes the five largest RSS consumers, making triage instant.

### Application server with known memory ceiling

Trigger earlier on servers where memory headroom is critical:

```bash
THRESHOLD=70
EMAIL_INTERVAL="1800"   # alert every 30 minutes while elevated
```

### JVM / Java monitoring

Java applications often consume large amounts of RSS due to heap allocation. The top-5 list makes it easy to confirm whether a JVM is the culprit:

```bash
THRESHOLD=85
ALERT_EMAIL="java-ops@company.com"
HOSTNAME_LABEL="jvm-prod-01"
```

### Container / sidecar check

```bash
HOSTNAME_LABEL="k8s-app-prod-03"
ERROR_LOG=""
EXECUTION_LOG=""
```

Logging disabled for container environments where stdout/stderr is captured by the runtime.

### Multi-environment infrastructure

Maintain separate copies per environment:

```
/opt/scripts/
├── memory-usage-monitor-prod.sh      # THRESHOLD=80
├── memory-usage-monitor-staging.sh   # THRESHOLD=90
```

```cron
*/5 * * * * /opt/scripts/memory-usage-monitor-prod.sh    >/dev/null 2>&1
*/5 * * * * /opt/scripts/memory-usage-monitor-staging.sh >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD` | `80` | Alert when memory usage exceeds this percentage. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/memory-usage-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/memory-usage-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/memory-usage-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/memory-usage-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/memory-usage-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/memory-usage-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview all actions including the top 5 process list, without performing anything. |
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