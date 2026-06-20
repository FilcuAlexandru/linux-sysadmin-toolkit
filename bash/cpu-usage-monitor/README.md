# cpu-usage-monitor.sh

Lightweight Bash script that monitors CPU usage and alerts when it exceeds a configurable threshold. Reads directly from `/proc/stat` for accurate, locale-independent measurements with no external binary required. Includes the top 5 CPU-consuming processes in every alert email so you know immediately what is causing the spike.

---

## Features

- **Kernel-first measurement** — reads `/proc/stat` (two snapshots 100 ms apart) for accurate CPU usage; falls back to `top(1)` if `/proc/stat` is unavailable.
- **Top 5 processes in email** — every alert email includes a ranked list of the five most CPU-intensive processes at the time of the alert.
- **Status tracking** — alerts once when CPU goes above the threshold, stays silent while it remains high, and sends a recovery email when it drops back below.
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

- **`top`** — fallback CPU source when `/proc/stat` is unavailable.
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/cpu-usage-monitor.sh \
     -o /opt/scripts/cpu-usage-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/cpu-usage-monitor.sh \
     -O /opt/scripts/cpu-usage-monitor.sh
```

### Manual copy

```bash
cp cpu-usage-monitor.sh /opt/scripts/cpu-usage-monitor.sh
chmod +x /opt/scripts/cpu-usage-monitor.sh
```

### Verify

```bash
/opt/scripts/cpu-usage-monitor.sh --version
/opt/scripts/cpu-usage-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Threshold

```bash
THRESHOLD=80
```

Alert fires when total CPU usage (user + system) exceeds this percentage. Set between `0` and `100`.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/cpu-usage-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/cpu-usage-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com infra@example.com manager@example.com"
```

All listed addresses receive the same alert email.

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/cpu-usage-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/cpu-usage-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/cpu-usage-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/cpu-usage-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
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
MAINTENANCE_FILE="${SCRIPT_DIR}/cpu-usage-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/cpu-usage-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/cpu-usage-monitor.status"
```

| Variable | Default | Description |
|---|---|---|
| `MAINTENANCE_FILE` | `<script_dir>/cpu-usage-monitor.maintenance` | Alerts suppressed while this file exists. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/cpu-usage-monitor.lock` | Used by `flock` to prevent overlapping runs. |
| `STATUS_FILE` | `<script_dir>/cpu-usage-monitor.status` | Tracks `OK` / `ALERT` state for deduplication and recovery. |

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: cpu-usage-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./cpu-usage-monitor.sh
```

Output when below threshold:

```
CPU Usage: 23.4%
```

Output when above threshold:

```
CPU Usage: 91.2%
ALERT: CPU usage above 80% on app-prod-01: 91.2%
```

### Dry-run

```bash
./cpu-usage-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/stat                   OK
  top                          OK
  ps                           OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Threshold:                   80%
  E-Mail:                      ops@example.com infra@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/cpu-usage-monitor-error.log
  Execution log:               /opt/scripts/logs/cpu-usage-monitor-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

CPU Usage: 91.2%
[dry-run] would raise alert: 91.2%
[dry-run] top 5 processes that would be included in email:
  1234       85.3%  java
  5678        3.1%  python3
  9012        1.2%  nginx
  3456        0.8%  postgres
  7890        0.4%  rsync
[dry-run] would email: ops@example.com infra@example.com (last sent: never)
```

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./cpu-usage-monitor.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./cpu-usage-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### CPU measurement (source priority)

1. **`/proc/stat`** (preferred) — reads two snapshots 100 ms apart and computes the delta. Accurate, locale-independent, no external binary needed. The formula:

   ```
   pct = (1 - delta_idle / delta_total) * 100
   ```

   This captures all non-idle time: user, nice, system, iowait, irq, softirq, steal. Arithmetic is done in `awk` to handle float math correctly.

2. **`top -bn1`** (fallback) — used only when `/proc/stat` is not readable. Less accurate (single snapshot, affected by locale) but widely available.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              CPU > THRESHOLD (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    │ + top 5     │
                    └──────┬──────┘
                           │
              CPU still > THRESHOLD (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              CPU <= THRESHOLD
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends. No repeated emails in between.

### Email body

Every alert email includes a formatted table of the five most CPU-intensive processes at the moment the alert fires:

```
CPU usage above 80% on app-prod-01: 91.2%

Top 5 CPU-consuming processes:
  1234       85.3%  java
  5678        3.1%  python3
  9012        1.2%  nginx
  3456        0.8%  postgres
  7890        0.4%  rsync
```

Columns: PID, CPU%, process name. Collected via `ps -eo pid,pcpu,comm --sort=-pcpu`. If `ps` is not available, the section shows `(ps not available)` and the email is still sent.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next alert (when transitioning from OK to ALERT), the script checks whether `EMAIL_INTERVAL` seconds have passed. This is a safety net; the status tracking above is the primary deduplication mechanism.

Recovery emails are never rate-limited.

### Maintenance mode

When `--maintenance` is called:
- If maintenance is off → creates the maintenance file, prints "enabled".
- If maintenance is on → removes the file, prints "disabled".

While the maintenance file exists, `alert()` logs the suppression and returns without printing to the console or sending email.

### Instance locking

Uses `flock(1)` to prevent overlapping runs. If another instance holds the lock, the new one exits silently with code 0. Skipped gracefully if `flock` is unavailable or the lock file cannot be created.

---

## Logging

### Directory structure

```
scripts/
├── cpu-usage-monitor.sh
├── cpu-usage-monitor.status
├── cpu-usage-monitor.email.state
├── cpu-usage-monitor.lock
├── cpu-usage-monitor.maintenance
└── logs/
    ├── cpu-usage-monitor-error.log
    ├── cpu-usage-monitor-error.log.2026-06-01_120000
    ├── cpu-usage-monitor-execution.log
    └── cpu-usage-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] threshold=80%
2026-06-20 10:00:01 RESULT 23.4% (ok)
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [app-prod-01] threshold=80%
2026-06-20 10:05:01 RESULT 91.2% (above threshold)
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [app-prod-01] threshold=80%
2026-06-20 10:10:01 RESULT 88.7% (above threshold)
2026-06-20 10:10:01 Already in ALERT state
2026-06-20 10:10:01 END
2026-06-20 10:45:01 START [app-prod-01] threshold=80%
2026-06-20 10:45:01 RESULT 21.3% (ok)
2026-06-20 10:45:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT 91.2%
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

### Cron

```cron
*/5 * * * * /opt/scripts/cpu-usage-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

To also capture output in syslog:

```cron
*/5 * * * * /opt/scripts/cpu-usage-monitor.sh 2>&1 | logger -t cpu-usage-monitor
```

### Checkmk (local check)

```bash
cp cpu-usage-monitor.sh /usr/lib/check_mk_agent/local/cpu-usage-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "cpu_usage_percent{host=\"${HOST_ID}\"} ${usage_pct}" \
    > /var/lib/node_exporter/cpu-usage.prom
```

### systemd timer

```ini
# /etc/systemd/system/cpu-usage-monitor.service
[Unit]
Description=CPU usage monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/cpu-usage-monitor.sh
```

```ini
# /etc/systemd/system/cpu-usage-monitor.timer
[Unit]
Description=Run CPU usage monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now cpu-usage-monitor.timer
```

---

## Use cases

### High-CPU alert with process identification

The primary use case: know immediately what process caused the spike without having to SSH in.

```bash
THRESHOLD=80
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
HOSTNAME_LABEL="web-prod-01"
```

An alert email at 03:00 will show not just "CPU is high" but also the five processes driving it.

### Tight threshold for batch job monitoring

Catch unexpected CPU usage during maintenance windows or batch jobs:

```bash
THRESHOLD=60
ALERT_EMAIL="batch-ops@company.com"
EMAIL_INTERVAL="900"   # alert every 15 minutes while elevated
```

### Container / sidecar check

```bash
HOSTNAME_LABEL="k8s-worker-prod-03"
ERROR_LOG=""
EXECUTION_LOG=""
```

Logging disabled for container environments where stdout/stderr is captured by the runtime.

### Multi-environment infrastructure

Maintain separate copies per environment:

```
/opt/scripts/
├── cpu-usage-monitor-prod.sh      # THRESHOLD=80, EMAIL_INTERVAL=3600
├── cpu-usage-monitor-staging.sh   # THRESHOLD=90, EMAIL_INTERVAL=300
```

```cron
*/5 * * * * /opt/scripts/cpu-usage-monitor-prod.sh    >/dev/null 2>&1
*/5 * * * * /opt/scripts/cpu-usage-monitor-staging.sh >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD` | `80` | Alert when CPU usage exceeds this percentage. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/cpu-usage-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/cpu-usage-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/cpu-usage-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/cpu-usage-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/cpu-usage-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/cpu-usage-monitor.status` | Tracks OK/ALERT state. |

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