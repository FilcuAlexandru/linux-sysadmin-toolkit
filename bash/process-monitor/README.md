# process-monitor.sh

Lightweight Bash script that checks whether one or more configured processes are running and alerts when any of them are down. Tracks state per process — alerts once when a process first goes down, stays silent while it remains down, and sends a recovery email when it comes back up.

---

## Features

- **Per-process status tracking** — alerts once on first failure, stays silent while down, recovers once when the process restarts.
- **Multi-process support** — any number of processes in a single array, each checked independently via `pgrep -x` (exact process name match).
- **Aggregated alerts** — all newly down processes reported in a single alert email per run.
- **Individual recovery emails** — one recovery email per process as each comes back up.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the full process list, and the current alert state.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — requires only `pgrep` (part of `procps`, available on all Linux distributions).

---

## Requirements

- **Bash 4.x+**
- **`pgrep`** — required for process detection (part of `procps` / `procps-ng`, pre-installed on virtually all Linux distributions).

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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/process-monitor.sh \
     -o /opt/scripts/process-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/process-monitor.sh \
     -O /opt/scripts/process-monitor.sh
```

### Manual copy

```bash
cp process-monitor.sh /opt/scripts/process-monitor.sh
chmod +x /opt/scripts/process-monitor.sh
```

### Verify

```bash
/opt/scripts/process-monitor.sh --version
/opt/scripts/process-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Processes

```bash
PROCESSES=("nginx" "sshd")
```

Add or remove names as needed. Each name is matched with `pgrep -x` — an **exact match** against the process binary name.

```bash
PROCESSES=(
    "nginx"
    "sshd"
    "postgres"
    "redis-server"
    "java"
)
```

#### Finding the correct process name

Use `pgrep -x <name>` directly to verify what name to use before adding a process:

```bash
# Test whether nginx is detected.
pgrep -x nginx && echo "found" || echo "not found"

# List all running process names to find the right one.
ps -eo comm= | sort -u
```

Some applications use binary names that differ from the service name:

| Service | `systemctl` name | Process name for `pgrep -x` |
|---|---|---|
| PostgreSQL | `postgresql` | `postgres` |
| Redis | `redis` | `redis-server` |
| Java apps (Tomcat, etc.) | varies | `java` |
| Node.js | `node` | `node` |
| Python apps | varies | `python3` or `python` |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/process-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/process-monitor.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/process-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/process-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/process-monitor-error.log` | Alerts and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/process-monitor-execution.log` | Every run (start, per-process result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers:

```bash
HOSTNAME_LABEL="app-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/process-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/process-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/process-monitor.status"
```

These are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: process-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./process-monitor.sh
```

```
nginx                    running
sshd                     running
postgres                 not running
redis-server             not running
ALERT: Processes not running on app-prod-01: postgres redis-server
```

Running processes appear in green, down processes in red (on terminals).

### Dry-run

```bash
./process-monitor.sh --dry-run
```

```
Prerequisites:
  pgrep                        OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Processes:                   4 configured
    [1] nginx
    [2] sshd
    [3] postgres
    [4] redis-server
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  ...

State:
  Currently in ALERT:          postgres redis-server
  Maintenance mode:            off
  Last email:                  1823s ago
  Lock directory writable:     OK

nginx                    running
sshd                     running
postgres                 not running
redis-server             not running
[dry-run] would raise alert: postgres redis-server
[dry-run] would skip email (rate-limited: last sent 1823s ago; interval 3600s)
```

### Maintenance mode

```bash
./process-monitor.sh --maintenance
# Output: Maintenance mode enabled

./process-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Process detection

Each process is checked with:

```bash
pgrep -x "$proc" >/dev/null 2>&1
```

`-x` requires an **exact match** against the process name (the `comm` field, i.e., the binary name, not the full command line). This avoids false positives from partial name matches. For example, `-x postgres` will match the `postgres` master process but not `postgres: replication worker`.

### Alert lifecycle (per process)

Each process is tracked independently:

```
                    ┌──────────────┐
                    │  not in      │
                    │  ALERT list  │
                    └──────┬───────┘
                           │
              pgrep -x fails (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► add to ALERT list
                    │ (aggregated)│
                    └──────┬──────┘
                           │
              pgrep -x still fails (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► remains in ALERT list
                    └──────┬──────┘
                           │
              pgrep -x succeeds
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► remove from ALERT list
                    └───────────────┘
```

If multiple processes go down on the same run, a single alert email lists all of them. Recovery emails are sent individually as each process comes back.

### State file format

`STATUS_FILE` holds a space-separated list of process names currently in ALERT state:

```
postgres redis-server
```

When all processes are running the file is empty. The file is updated on every state change.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. Status tracking is the primary deduplication mechanism; rate-limiting is a safety net for rapid consecutive failures.

Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── process-monitor.sh
├── process-monitor.status
├── process-monitor.email.state
├── process-monitor.lock
├── process-monitor.maintenance
└── logs/
    ├── process-monitor-error.log
    ├── process-monitor-error.log.2026-06-01_120000
    ├── process-monitor-execution.log
    └── process-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] checking 4 process(es): nginx sshd postgres redis-server
2026-06-20 10:00:01 OK nginx
2026-06-20 10:00:01 OK sshd
2026-06-20 10:00:01 DOWN postgres
2026-06-20 10:00:01 DOWN redis-server
2026-06-20 10:00:01 ALERT postgres redis-server
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [app-prod-01] checking 4 process(es): nginx sshd postgres redis-server
2026-06-20 10:05:01 OK nginx
2026-06-20 10:05:01 OK sshd
2026-06-20 10:05:01 DOWN postgres
2026-06-20 10:05:01 DOWN redis-server
2026-06-20 10:05:01 RESULT all processes running
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [app-prod-01] checking 4 process(es): nginx sshd postgres redis-server
2026-06-20 10:10:01 OK nginx
2026-06-20 10:10:01 OK sshd
2026-06-20 10:10:01 OK postgres
2026-06-20 10:10:01 RECOVERY postgres
2026-06-20 10:10:01 DOWN redis-server
2026-06-20 10:10:01 END
```

### Error log

```
2026-06-20 10:00:01 ALERT postgres redis-server
2026-06-20 10:00:01 EMAIL sent to ops@example.com
2026-06-20 10:10:01 RECOVERY EMAIL sent for postgres to ops@example.com
2026-06-20 10:15:01 RECOVERY EMAIL sent for redis-server to ops@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Self-contained — no dependency on `logrotate`.

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
STATUS_FILE="/tmp/process-monitor.status"
STATE_FILE="/tmp/process-monitor.email.state"
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
  name: process-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: process-monitor
            image: alpine/bash
            command: ["/scripts/process-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/process-monitor.sh >/dev/null 2>&1
```

### Alongside service-watchdog.sh

`process-monitor.sh` detects and alerts. `service-watchdog.sh` detects and restarts. Run both together:

```cron
*/5 * * * * /opt/scripts/service-watchdog.sh  >/dev/null 2>&1
*/5 * * * * /opt/scripts/process-monitor.sh   >/dev/null 2>&1
```

`service-watchdog.sh` attempts a restart; `process-monitor.sh` confirms the process came back up and sends a recovery email when it does.

### Checkmk (local check)

```bash
cp process-monitor.sh /usr/lib/check_mk_agent/local/process-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
for proc in "${PROCESSES[@]}"; do
    if pgrep -x "$proc" >/dev/null 2>&1; then
        echo "process_up{host=\"${HOST_ID}\",process=\"${proc}\"} 1"
    else
        echo "process_up{host=\"${HOST_ID}\",process=\"${proc}\"} 0"
    fi
done > /var/lib/node_exporter/process-monitor.prom
```

### systemd timer

```ini
# /etc/systemd/system/process-monitor.service
[Unit]
Description=Process monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/process-monitor.sh
```

```ini
# /etc/systemd/system/process-monitor.timer
[Unit]
Description=Run process monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### Web stack monitoring

```bash
PROCESSES=(
    "nginx"
    "php-fpm"
    "postgres"
    "redis-server"
)
ALERT_EMAIL="ops@company.com dev@company.com"
```

### Java application server

```bash
PROCESSES=(
    "java"
    "nginx"
    "postgres"
)
HOSTNAME_LABEL="jvm-prod-01"
ALERT_EMAIL="app-ops@company.com"
```

### Minimal infrastructure

```bash
PROCESSES=(
    "sshd"
    "cron"
)
ALERT_EMAIL="infra@company.com"
EMAIL_INTERVAL="1800"
```

### Container sidecar

```bash
PROCESSES=("myapp")
HOSTNAME_LABEL="k8s-app-prod-03"
ERROR_LOG=""
EXECUTION_LOG=""
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `PROCESSES` | `("nginx" "sshd")` | Array of process names to check with `pgrep -x`. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/process-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/process-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/process-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/process-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/process-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/process-monitor.status` | Tracks process names currently in ALERT state. |

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