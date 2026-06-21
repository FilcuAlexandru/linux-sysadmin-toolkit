# load-monitor.sh

Lightweight Bash script that monitors system load average and alerts when it exceeds a dynamic threshold based on the number of CPU cores. Reads directly from `/proc/loadavg` and `/proc/cpuinfo` — no external binaries required for the core measurement.

---

## Features

- **Core-aware threshold** — the alert limit is `LOAD_RATIO × number_of_CPU_cores`, automatically adapting to single-core and multi-core systems.
- **Kernel-first measurement** — reads `/proc/loadavg` (always present on Linux) and `/proc/cpuinfo` for core count; falls back to `nproc(1)` then `1` if `/proc/cpuinfo` is unavailable.
- **Status tracking** — alerts once when load goes above the threshold, stays silent while it remains high, and sends a recovery email when it drops back below.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the effective limit (`cores × ratio`) and all dependencies before previewing actions.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux kernel with `/proc` mounted** — required for `/proc/loadavg` (load data) and `/proc/cpuinfo` (core count).

Optional (the script warns and continues without them):

- **`nproc`** — fallback for core count when `/proc/cpuinfo` is unavailable.
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/load-monitor.sh \
     -o /opt/scripts/load-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/load-monitor.sh \
     -O /opt/scripts/load-monitor.sh
```

### Manual copy

```bash
cp load-monitor.sh /opt/scripts/load-monitor.sh
chmod +x /opt/scripts/load-monitor.sh
```

### Verify

```bash
/opt/scripts/load-monitor.sh --version
/opt/scripts/load-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Load threshold

```bash
LOAD_RATIO=1.5
```

The alert fires when the **1-minute load average** exceeds `LOAD_RATIO × number_of_CPU_cores`.

| Scenario | Cores | `LOAD_RATIO` | Alert when load > |
|---|---|---|---|
| Default | 4 | 1.5 | 6.00 |
| Default | 8 | 1.5 | 12.00 |
| Tight (latency-sensitive) | 4 | 1.0 | 4.00 |
| Relaxed (batch/compute) | 8 | 3.0 | 24.00 |

The effective limit for the current system is shown in `--dry-run` output:

```
Effective limit:             6.00 (4 cores × 1.5)
```

#### When to tune `LOAD_RATIO`

- **Lower** (e.g., `1.0`) — for latency-sensitive services (web servers, APIs) where high load directly impacts response time.
- **Default** (`1.5`) — a reasonable general-purpose threshold that allows for brief spikes without false alerts.
- **Higher** (e.g., `2.0`–`3.0`) — for batch processing, build servers, or compute workloads that are expected to run at high load.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/load-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/load-monitor.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/load-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/load-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/load-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/load-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers:

```bash
HOSTNAME_LABEL="compute-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable → `hostname` command → `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/load-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/load-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/load-monitor.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: load-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./load-monitor.sh
```

Output when below threshold:

```
Load average: 1.23 0.87 0.65  (cores: 4  limit: 6.00)
```

Output when above threshold:

```
Load average: 8.42 6.11 4.23  (cores: 4  limit: 6.00)
ALERT: High load average on compute-prod-01: 1-min load 8.42 over limit 6.00 (cores 4)
```

The load average values shown are: 1-minute (highlighted red when above limit), 5-minute, 15-minute.

### Dry-run

```bash
./load-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/loadavg                OK
  /proc/cpuinfo                OK
  nproc                        OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     compute-prod-01
  Load ratio:                  1.5
  CPU cores:                   4
  Effective limit:             6.00 (4 cores × 1.5)
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/load-monitor-error.log
  Execution log:               /opt/scripts/logs/load-monitor-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

Load average: 1.23 0.87 0.65  (cores: 4  limit: 6.00)
```

### Maintenance mode

```bash
./load-monitor.sh --maintenance
# Output: Maintenance mode enabled

./load-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Load measurement

```
/proc/loadavg  →  load1, load5, load15
/proc/cpuinfo  →  core count (count of 'processor' lines)
    │
    ├── /proc/cpuinfo unavailable → nproc(1)
    └── nproc unavailable         → assume 1 core
```

The limit is computed as `LOAD_RATIO × cores` in `awk` (float arithmetic). The comparison `load1 > limit` is also done in `awk` to avoid bash integer-only math.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              load1 > LOAD_RATIO × cores (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              load1 still > limit (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              load1 <= limit
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Why load average and not CPU percent

Load average and CPU usage are complementary metrics:

- **CPU usage** (`cpu-usage-monitor.sh`) — what percentage of CPU time is being used. Misses I/O wait and queue depth.
- **Load average** — the number of processes in the run queue (running or waiting for CPU/I/O). A high load with low CPU usage typically means I/O bottleneck. A high load with high CPU usage means CPU saturation.

The 1-minute average is used for alerting (most responsive). The 5-minute and 15-minute averages are shown for context, allowing you to see whether load is rising, stable, or already declining.

---

## Logging

### Directory structure

```
scripts/
├── load-monitor.sh
├── load-monitor.status
├── load-monitor.email.state
├── load-monitor.lock
├── load-monitor.maintenance
└── logs/
    ├── load-monitor-error.log
    ├── load-monitor-error.log.2026-06-01_120000
    ├── load-monitor-execution.log
    └── load-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [compute-prod-01] ratio=1.5
2026-06-20 10:00:01 RESULT load=1.23 limit=6.00 cores=4 (ok)
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [compute-prod-01] ratio=1.5
2026-06-20 10:05:01 RESULT load=8.42 limit=6.00 cores=4 (above threshold)
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [compute-prod-01] ratio=1.5
2026-06-20 10:10:01 RESULT load=7.81 limit=6.00 cores=4 (above threshold)
2026-06-20 10:10:01 Already in ALERT state
2026-06-20 10:10:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT 1-min load 8.42 over limit 6.00 (cores 4)
2026-06-20 10:05:01 EMAIL sent to ops@example.com
2026-06-20 10:45:01 RECOVERY EMAIL sent to ops@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Self-contained — no dependency on `logrotate`.

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
STATUS_FILE="/tmp/load-monitor.status"
STATE_FILE="/tmp/load-monitor.email.state"
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
  name: load-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: load-monitor
            image: alpine/bash
            command: ["/scripts/load-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/load-monitor.sh >/dev/null 2>&1
```

### Checkmk (local check)

```bash
cp load-monitor.sh /usr/lib/check_mk_agent/local/load-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
echo "load_average_1min{host=\"${HOST_ID}\"} ${load1}" \
    > /var/lib/node_exporter/load.prom
```

### systemd timer

```ini
# /etc/systemd/system/load-monitor.service
[Unit]
Description=Load average monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/load-monitor.sh
```

```ini
# /etc/systemd/system/load-monitor.timer
[Unit]
Description=Run load monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### General-purpose server

```bash
LOAD_RATIO=1.5
ALERT_EMAIL="ops@company.com"
```

### Latency-sensitive web server

Alert early before load impacts response times:

```bash
LOAD_RATIO=1.0   # alert when any core is fully saturated
ALERT_EMAIL="web-ops@company.com"
EMAIL_INTERVAL="1800"
```

### Batch / compute server

Allow high load during expected compute bursts:

```bash
LOAD_RATIO=3.0   # alert only when load is 3× the core count
ALERT_EMAIL="batch-ops@company.com"
```

### Using alongside cpu-usage-monitor

Load and CPU monitors are complementary. Run both:

```cron
*/5 * * * * /opt/scripts/cpu-usage-monitor.sh  >/dev/null 2>&1
*/5 * * * * /opt/scripts/load-monitor.sh       >/dev/null 2>&1
```

- `cpu-usage-monitor` catches CPU saturation.
- `load-monitor` catches I/O bottlenecks and process queue buildup.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `LOAD_RATIO` | `1.5` | Alert when 1-min load exceeds `LOAD_RATIO × cores`. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/load-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/load-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/load-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/load-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/load-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/load-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration including the effective limit (`cores × ratio`), and preview actions without performing them. |
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