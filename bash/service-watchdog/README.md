# service-watchdog.sh

Lightweight Bash script that automatically restarts any configured service that is not running. Idempotent — services already running are left untouched. Alerts on restart failure (not on the restart action itself) and sends a recovery email when all services are confirmed running again after a previous failure.

---

## Features

- **Automatic restart** — detects stopped services and restarts them with `systemctl restart`.
- **Idempotent** — checks each service with `pgrep -x` before acting; running services are skipped without any action.
- **Restart failure alerting** — alerts only when `systemctl restart` fails, not when it succeeds. A successful restart is expected watchdog behaviour.
- **Status tracking** — alerts once when a restart failure occurs, stays silent while it persists, and sends a recovery email when all services are running again.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the service list, and which services would be restarted.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.

---

## Requirements

- **Bash 4.x+**
- **`systemctl`** — required for restarting services (systemd).
- **`pgrep`** — required for running check (part of `procps`, pre-installed on all Linux distributions).

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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-watchdog.sh \
     -o /opt/scripts/service-watchdog.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-watchdog.sh \
     -O /opt/scripts/service-watchdog.sh
```

### Manual copy

```bash
cp service-watchdog.sh /opt/scripts/service-watchdog.sh
chmod +x /opt/scripts/service-watchdog.sh
```

### Verify

```bash
/opt/scripts/service-watchdog.sh --version
/opt/scripts/service-watchdog.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Services

```bash
SERVICES=("nginx" "sshd")
```

Each name is:
- Checked with `pgrep -x <name>` to determine if it is running.
- Passed to `systemctl restart <name>` when the service is not running.

```bash
SERVICES=(
    "nginx"
    "sshd"
    "postgres"
    "redis-server"
)
```

See `process-monitor.sh` for a table of common service vs. binary name discrepancies (e.g., `postgresql` service → `postgres` binary).

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/service-watchdog.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/service-watchdog.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/service-watchdog-error.log"
EXECUTION_LOG="${LOG_DIR}/service-watchdog-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/service-watchdog-error.log` | Restart failures and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-watchdog-execution.log` | Every run (start, result per service, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

```bash
HOSTNAME_LABEL="app-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/service-watchdog.maintenance"
LOCK_FILE="${SCRIPT_DIR}/service-watchdog.lock"
STATUS_FILE="${SCRIPT_DIR}/service-watchdog.status"
```

These are managed automatically.

---

## Usage

```
Usage: service-watchdog.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./service-watchdog.sh
```

When all services are running:

```
nginx                    running
sshd                     running
postgres                 running
```

When a service needs to be restarted:

```
nginx                    running
sshd                     running
postgres                 not running
postgres                 restarted
```

When a restart fails:

```
nginx                    running
postgres                 not running
postgres                 FAILED to restart
ALERT: Service restart failure on app-prod-01: failed to restart: postgres
```

### Dry-run

```bash
./service-watchdog.sh --dry-run
```

```
Prerequisites:
  systemctl                    OK
  pgrep                        OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Services:                    3 configured
    [1] nginx
    [2] sshd
    [3] postgres
  E-Mail:                      ops@example.com
  ...

nginx                    running
sshd                     running
postgres                 not running
postgres                 would restart
```

### Maintenance mode

```bash
./service-watchdog.sh --maintenance
# Output: Maintenance mode enabled

./service-watchdog.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Alert philosophy

`service-watchdog.sh` is an **action** script. Restarting a stopped service is the expected watchdog behaviour — it is not an alert condition. The script alerts only when it **tries to restart a service and fails**, which indicates a genuine problem the watchdog cannot resolve automatically.

```
Service not running
        │
        ├── systemctl restart succeeds ──── log RESTARTED, no alert
        │
        └── systemctl restart fails ──────── log FAILED → ALERT
```

This means: the watchdog silently keeps services running. You are only notified when it cannot — requiring manual intervention.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              systemctl restart fails (first failure)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              restart still failing (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              all services running (restart success or already up)
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

Recovery is triggered when a run completes with zero failures — whether because the restart succeeded on this run, or the service came back up on its own between runs.

### Idempotent behaviour

Each service is checked with `pgrep -x` before attempting to restart. If the process is already running:
- No `systemctl restart` is called.
- The service is printed as "running".
- No alert or email is sent.

This makes the script safe to run on a cron schedule: when all services are healthy it produces minimal output and performs no unnecessary restarts.

---

## Logging

### Directory structure

```
scripts/
├── service-watchdog.sh
├── service-watchdog.status
├── service-watchdog.email.state
├── service-watchdog.lock
├── service-watchdog.maintenance
└── logs/
    ├── service-watchdog-error.log
    ├── service-watchdog-error.log.2026-06-01_120000
    ├── service-watchdog-execution.log
    └── service-watchdog-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] managing 3 service(s): nginx sshd postgres
2026-06-20 10:00:01 RUNNING nginx
2026-06-20 10:00:01 RUNNING sshd
2026-06-20 10:00:01 RESTARTED postgres
2026-06-20 10:00:01 RESULT restarted: postgres
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [app-prod-01] managing 3 service(s): nginx sshd postgres
2026-06-20 10:05:01 RUNNING nginx
2026-06-20 10:05:01 RUNNING sshd
2026-06-20 10:05:01 FAILED postgres
2026-06-20 10:05:01 RESULT 1 service(s) failed to restart: postgres
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [app-prod-01] managing 3 service(s): nginx sshd postgres
2026-06-20 10:10:01 RUNNING nginx
2026-06-20 10:10:01 RUNNING sshd
2026-06-20 10:10:01 RUNNING postgres
2026-06-20 10:10:01 RESULT all services running
2026-06-20 10:10:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT failed to restart: postgres
2026-06-20 10:05:01 EMAIL sent to ops@example.com
2026-06-20 10:10:01 RECOVERY EMAIL sent to ops@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Self-contained — no dependency on `logrotate`.

---

## Integration

### Cron

```cron
*/5 * * * * /opt/scripts/service-watchdog.sh >/dev/null 2>&1
```

Checks and restarts services every 5 minutes.

### Full service monitoring stack

Combine all four service scripts for complete coverage:

| Script | Action | Alert on |
|---|---|---|
| `process-monitor.sh` | Monitor only | Process not running |
| `service-start.sh` | Start if not running | Start failure |
| `service-stop.sh` | Stop if running | Stop failure |
| `service-watchdog.sh` | Restart if not running | Restart failure |

Typical cron setup using `service-watchdog.sh` as the active recovery and `process-monitor.sh` for visibility:

```cron
*/5 * * * * /opt/scripts/service-watchdog.sh  >/dev/null 2>&1
*/5 * * * * /opt/scripts/process-monitor.sh   >/dev/null 2>&1
```

`service-watchdog.sh` attempts the restart. If it succeeds, `process-monitor.sh` detects the process is running and sends a recovery email.

### Alongside systemd-failed-monitor.sh

A service can be restarted by the watchdog but still show a failed unit in systemd if the unit hit its restart limit. Run both:

```cron
*/5 * * * * /opt/scripts/service-watchdog.sh         >/dev/null 2>&1
*/5 * * * * /opt/scripts/systemd-failed-monitor.sh   >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/service-watchdog.service
[Unit]
Description=Service watchdog check

[Service]
Type=oneshot
ExecStart=/opt/scripts/service-watchdog.sh
```

```ini
# /etc/systemd/system/service-watchdog.timer
[Unit]
Description=Run service watchdog every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now service-watchdog.timer
```

---

## Use cases

### General web stack

```bash
SERVICES=(
    "nginx"
    "php-fpm"
    "postgres"
    "redis-server"
)
ALERT_EMAIL="ops@company.com"
```

### Java application server

```bash
SERVICES=(
    "java"
    "nginx"
)
HOSTNAME_LABEL="jvm-prod-01"
ALERT_EMAIL="app-ops@company.com"
EMAIL_INTERVAL="1800"
```

### Critical single service

```bash
SERVICES=("postgres")
ALERT_EMAIL="dba@company.com infra@company.com"
EMAIL_INTERVAL="900"   # alert every 15 minutes while failing
```

### Multiple environments

```
/opt/scripts/
├── watchdog-prod.sh      # SERVICES=("nginx" "postgres" "redis-server")
├── watchdog-staging.sh   # SERVICES=("nginx" "postgres")
```

```cron
*/5 * * * * /opt/scripts/watchdog-prod.sh    >/dev/null 2>&1
*/5 * * * * /opt/scripts/watchdog-staging.sh >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `SERVICES` | `("nginx" "sshd")` | Array of service names to restart if not running. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/service-watchdog.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/service-watchdog-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-watchdog-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/service-watchdog.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/service-watchdog.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/service-watchdog.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, and list services that would be restarted — without performing any action. |
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