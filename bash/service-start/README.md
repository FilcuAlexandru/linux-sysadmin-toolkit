# service-start.sh

Lightweight Bash script that starts any configured service that is not currently running. Idempotent — services already running are left untouched. Alerts on start failure (not on the start action itself) and sends a recovery email when all services are successfully running after a previous failure.

---

## Features

- **Idempotent** — checks each service with `pgrep -x` before attempting to start; services already running are skipped without any action.
- **Start failure alerting** — alerts only when `systemctl start` fails, not when services are started normally. Starting a stopped service is expected behaviour, not an alert condition.
- **Status tracking** — alerts once when a start failure occurs, stays silent while it persists, and sends a recovery email when all services are running.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the service list, and which services would be started.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.

---

## Requirements

- **Bash 4.x+**
- **`systemctl`** — required for starting services (systemd).
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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-start.sh \
     -o /opt/scripts/service-start.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/service-start.sh \
     -O /opt/scripts/service-start.sh
```

### Manual copy

```bash
cp service-start.sh /opt/scripts/service-start.sh
chmod +x /opt/scripts/service-start.sh
```

### Verify

```bash
/opt/scripts/service-start.sh --version
/opt/scripts/service-start.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Services

```bash
SERVICES=("nginx" "sshd")
```

Add or remove services as needed. Each name is:
- Passed to `systemctl start <name>` when the service is not running.
- Checked with `pgrep -x <name>` (exact binary name match) to determine if it is running.

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
STATE_FILE="${SCRIPT_DIR}/service-start.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/service-start.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/service-start-error.log"
EXECUTION_LOG="${LOG_DIR}/service-start-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/service-start-error.log` | Start failures and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-start-execution.log` | Every run (start, result per service, end). `""` = disabled. |
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
MAINTENANCE_FILE="${SCRIPT_DIR}/service-start.maintenance"
LOCK_FILE="${SCRIPT_DIR}/service-start.lock"
STATUS_FILE="${SCRIPT_DIR}/service-start.status"
```

These are managed automatically.

---

## Usage

```
Usage: service-start.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./service-start.sh
```

When all services are already running:

```
nginx                    already running
sshd                     already running
postgres                 already running
```

When a service needs to be started:

```
nginx                    already running
postgres                 starting...
postgres                 started
```

When a start fails:

```
nginx                    already running
postgres                 starting...
postgres                 FAILED to start
ALERT: Service start failure on app-prod-01: failed to start: postgres
```

### Dry-run

```bash
./service-start.sh --dry-run
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

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

nginx                    already running
sshd                     already running
postgres                 would start
```

### Maintenance mode

```bash
./service-start.sh --maintenance
# Output: Maintenance mode enabled

./service-start.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Alert philosophy

`service-start.sh` is an **action** script, not a pure monitor. Starting a stopped service is expected and normal — it is not an alert condition. The script alerts only when it **tries to start a service and fails**, which indicates a genuine problem (misconfiguration, dependency issue, crashed unit that cannot recover).

```
Service not running
        │
        ├── systemctl start succeeds ──── log STARTED, no alert
        │
        └── systemctl start fails ──────── log FAILED → ALERT
```

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              systemctl start fails (first failure)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              start still failing (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              all services running (start success or already up)
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

Recovery is triggered when a run completes with zero failures — whether because the start succeeded, or because the service came back up on its own between runs.

### Idempotent behaviour

Each service is checked with `pgrep -x` before attempting to start it. If the process is already running:
- No `systemctl start` is called.
- The service is printed as "already running".
- No alert or email is sent.

This makes the script safe to run on a cron schedule without producing noise when services are healthy.

---

## Logging

### Directory structure

```
scripts/
├── service-start.sh
├── service-start.status
├── service-start.email.state
├── service-start.lock
├── service-start.maintenance
└── logs/
    ├── service-start-error.log
    ├── service-start-error.log.2026-06-01_120000
    ├── service-start-execution.log
    └── service-start-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 02:00:01 START [app-prod-01] managing 3 service(s): nginx sshd postgres
2026-06-20 02:00:01 RUNNING nginx
2026-06-20 02:00:01 RUNNING sshd
2026-06-20 02:00:01 STARTED postgres
2026-06-20 02:00:01 RESULT started: postgres
2026-06-20 02:00:01 END
```

On failure:

```
2026-06-20 02:00:01 START [app-prod-01] managing 3 service(s): nginx sshd postgres
2026-06-20 02:00:01 RUNNING nginx
2026-06-20 02:00:01 RUNNING sshd
2026-06-20 02:00:01 FAILED postgres
2026-06-20 02:00:01 RESULT 1 service(s) failed to start: postgres
2026-06-20 02:00:01 END
```

### Error log

```
2026-06-20 02:00:01 ALERT failed to start: postgres
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
STATUS_FILE="/tmp/service-start.status"
STATE_FILE="/tmp/service-start.email.state"
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
  name: service-start
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: service-start
            image: alpine/bash
            command: ["/scripts/service-start.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/service-start.sh >/dev/null 2>&1
```

### Alongside process-monitor.sh and service-watchdog.sh

These three scripts form a natural hierarchy:

| Script | Action | Alert on |
|---|---|---|
| `process-monitor.sh` | Monitor only | Process not running |
| `service-start.sh` | Start if not running | Start failure |
| `service-watchdog.sh` | Restart if not running | Restart failure |

Use `service-start.sh` when you want to start services that should be running but don't need aggressive restart logic. Use `service-watchdog.sh` when you want automatic restart attempts.

### systemd timer

```ini
# /etc/systemd/system/service-start.service
[Unit]
Description=Service start check

[Service]
Type=oneshot
ExecStart=/opt/scripts/service-start.sh
```

```ini
# /etc/systemd/system/service-start.timer
[Unit]
Description=Run service start check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### Ensure core services are running at boot

```bash
SERVICES=("sshd" "cron" "rsyslog")
ALERT_EMAIL="infra@company.com"
```

Run via a systemd timer at boot and every 5 minutes thereafter.

### Web stack recovery

```bash
SERVICES=("nginx" "php-fpm" "postgres")
ALERT_EMAIL="web-ops@company.com"
EMAIL_INTERVAL="900"
```

### Multiple environments

```
/opt/scripts/
├── service-start-prod.sh      # SERVICES=("nginx" "postgres" "redis-server")
├── service-start-staging.sh   # SERVICES=("nginx" "postgres")
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `SERVICES` | `("nginx" "sshd")` | Array of service names to start if not running. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/service-start.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/service-start-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/service-start-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/service-start.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/service-start.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/service-start.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, and list services that would be started — without performing any action. |
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