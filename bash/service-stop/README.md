# service-stop.sh

Lightweight Bash script that stops any configured service that is currently running. Idempotent — services already stopped are left untouched. Alerts on stop failure (not on the stop action itself) and sends a recovery email when all services are successfully stopped after a previous failure.

---

## Features

- **Idempotent** — checks each service with `pgrep -x` before attempting to stop; services already stopped are skipped without any action.
- **Stop failure alerting** — alerts only when `systemctl stop` fails, not when services are stopped normally.
- **Status tracking** — alerts once when a stop failure occurs, stays silent while it persists, and sends a recovery email when all services are confirmed stopped.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the service list, and which services would be stopped.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.

---

## Requirements

- **Bash 4.x+**
- **`systemctl`** — required for stopping services (systemd).
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-stop.sh \
     -o /opt/scripts/service-stop.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-stop.sh \
     -O /opt/scripts/service-stop.sh
```

### Manual copy

```bash
cp service-stop.sh /opt/scripts/service-stop.sh
chmod +x /opt/scripts/service-stop.sh
```

### Verify

```bash
/opt/scripts/service-stop.sh --version
/opt/scripts/service-stop.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line.

### Services

```bash
SERVICES=("nginx" "sshd")
```

Each name is:
- Checked with `pgrep -x <name>` to determine if it is running.
- Passed to `systemctl stop <name>` when the service is running.

```bash
SERVICES=(
    "nginx"
    "php-fpm"
    "redis-server"
)
```

See `process-monitor.sh` for a table of common service vs. binary name discrepancies (e.g., `postgresql` service → `postgres` binary).

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/service-stop.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/service-stop.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com infra@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/service-stop-error.log"
EXECUTION_LOG="${LOG_DIR}/service-stop-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/service-stop-error.log` | Stop failures and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-stop-execution.log` | Every run (start, result per service, end). `""` = disabled. |
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
MAINTENANCE_FILE="${SCRIPT_DIR}/service-stop.maintenance"
LOCK_FILE="${SCRIPT_DIR}/service-stop.lock"
STATUS_FILE="${SCRIPT_DIR}/service-stop.status"
```

These are managed automatically.

---

## Usage

```
Usage: service-stop.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./service-stop.sh
```

When all services are already stopped:

```
nginx                    already stopped
php-fpm                  already stopped
```

When a service needs to be stopped:

```
nginx                    stopping...
nginx                    stopped
php-fpm                  already stopped
```

When a stop fails:

```
nginx                    stopping...
nginx                    FAILED to stop
ALERT: Service stop failure on app-prod-01: failed to stop: nginx
```

### Dry-run

```bash
./service-stop.sh --dry-run
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
  Services:                    2 configured
    [1] nginx
    [2] php-fpm
  E-Mail:                      ops@example.com
  ...

nginx                    would stop
php-fpm                  already stopped
```

### Maintenance mode

```bash
./service-stop.sh --maintenance
# Output: Maintenance mode enabled

./service-stop.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Alert philosophy

`service-stop.sh` is an **action** script. Stopping a running service is expected and normal — it is not an alert condition. The script alerts only when it **tries to stop a service and fails**, which indicates a genuine problem (the service is stuck, a dependency is blocking the stop, or systemd itself has an issue).

```
Service running
        │
        ├── systemctl stop succeeds ──── log STOPPED, no alert
        │
        └── systemctl stop fails ──────── log FAILED → ALERT
```

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              systemctl stop fails (first failure)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              stop still failing (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              all services stopped (stop success or already down)
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

Recovery is triggered when a run completes with zero failures — whether because the stop succeeded, or because the service went down on its own between runs.

### Idempotent behaviour

Each service is checked with `pgrep -x` before attempting to stop. If the process is not running:
- No `systemctl stop` is called.
- The service is printed as "already stopped".
- No alert or email is sent.

---

## Logging

### Directory structure

```
scripts/
├── service-stop.sh
├── service-stop.status
├── service-stop.email.state
├── service-stop.lock
├── service-stop.maintenance
└── logs/
    ├── service-stop-error.log
    ├── service-stop-error.log.2026-06-01_120000
    ├── service-stop-execution.log
    └── service-stop-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 02:00:01 START [app-prod-01] managing 2 service(s): nginx php-fpm
2026-06-20 02:00:01 STOPPED nginx
2026-06-20 02:00:01 STOPPED already php-fpm
2026-06-20 02:00:01 RESULT stopped: nginx
2026-06-20 02:00:01 END
```

On failure:

```
2026-06-20 02:00:01 START [app-prod-01] managing 2 service(s): nginx php-fpm
2026-06-20 02:00:01 FAILED nginx
2026-06-20 02:00:01 STOPPED already php-fpm
2026-06-20 02:00:01 RESULT 1 service(s) failed to stop: nginx
2026-06-20 02:00:01 END
```

### Error log

```
2026-06-20 02:00:01 ALERT failed to stop: nginx
2026-06-20 02:00:01 EMAIL sent to ops@example.com
2026-06-20 02:05:01 RECOVERY EMAIL sent to ops@example.com
```

---

## Integration

### Container usage (Kubernetes / Docker)

When running inside a container, set `HOSTNAME_LABEL` to a meaningful name:

```bash
HOSTNAME_LABEL="app-prod-01"
```

On read-only container filesystems, point state files to a writable volume:

```bash
STATUS_FILE="/tmp/service-stop.status"
STATE_FILE="/tmp/service-stop.email.state"
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
  name: service-stop
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: service-stop
            image: alpine/bash
            command: ["/scripts/service-stop.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Companion scripts

| Script | Action | Alert on |
|---|---|---|
| `process-monitor.sh` | Monitor only | Process not running |
| `service-start.sh` | Start if not running | Start failure |
| `service-stop.sh` | Stop if running | Stop failure |
| `service-watchdog.sh` | Restart if not running | Restart failure |

`service-stop.sh` is typically used for controlled shutdown sequences, maintenance windows, or pre-backup stops — not for continuous cron monitoring.

### Controlled shutdown before maintenance

```bash
# 1. Enter maintenance mode to suppress process/watchdog alerts during the stop.
/opt/scripts/process-monitor.sh   --maintenance
/opt/scripts/service-watchdog.sh  --maintenance

# 2. Stop services.
/opt/scripts/service-stop.sh

# 3. Perform maintenance.
# ...

# 4. Start services.
/opt/scripts/service-start.sh

# 5. Exit maintenance mode.
/opt/scripts/process-monitor.sh   --maintenance
/opt/scripts/service-watchdog.sh  --maintenance
```

### Pre-backup stop

```bash
#!/usr/bin/env bash
# Stop postgres before backup, start it after.
/opt/scripts/service-stop.sh  || exit 1
/opt/scripts/directory-backup.sh
/opt/scripts/service-start.sh
```

---

## Use cases

### Controlled service shutdown

```bash
SERVICES=("nginx" "php-fpm")
ALERT_EMAIL="ops@company.com"
```

### Pre-backup stop

```bash
SERVICES=("postgres")
ALERT_EMAIL="dba@company.com"
```

### Multi-stage shutdown

```
/opt/scripts/
├── stop-frontend.sh    # SERVICES=("nginx" "php-fpm")
├── stop-backend.sh     # SERVICES=("gunicorn" "celery")
├── stop-database.sh    # SERVICES=("postgres" "redis-server")
```

Run in sequence for ordered shutdown:

```bash
/opt/scripts/stop-frontend.sh  || exit 1
/opt/scripts/stop-backend.sh   || exit 1
/opt/scripts/stop-database.sh  || exit 1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `SERVICES` | `("nginx" "sshd")` | Array of service names to stop if running. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/service-stop.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/service-stop-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-stop-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/service-stop.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/service-stop.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/service-stop.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, and list services that would be stopped — without performing any action. |
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