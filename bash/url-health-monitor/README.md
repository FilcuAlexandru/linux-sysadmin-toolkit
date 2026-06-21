# url-health-monitor.sh

Lightweight Bash script that checks one or more URLs and alerts when any of them return an unhealthy HTTP status. Tracks state per URL — alerts once when a URL first fails, stays silent while it remains down, and sends a recovery email when it comes back up.

---

## Features

- **Per-URL status tracking** — alerts once on first failure, stays silent while down, recovers once when back up.
- **HEAD→GET fallback** — tries a lightweight HEAD request first; automatically retries with GET if the server returns 405 (Method Not Allowed).
- **Strict 2xx mode** — optional `EXPECTED_2XX=1` rejects 3xx redirects, treating them as failures.
- **Multi-URL support** — any number of URLs in a single array, each checked independently.
- **Aggregated alerts** — all newly failed URLs reported in a single alert email per run.
- **Individual recovery emails** — one recovery email per URL as each comes back up.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every check) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the full URL list, and the current alert state.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, requires only `curl` and Bash.

---

## Requirements

- **Bash 4.x+**
- **`curl`** — required for HTTP checks.

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
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/url-health-monitor.sh \
     -o /opt/scripts/url-health-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/url-health-monitor.sh \
     -O /opt/scripts/url-health-monitor.sh
```

### Manual copy

```bash
cp url-health-monitor.sh /opt/scripts/url-health-monitor.sh
chmod +x /opt/scripts/url-health-monitor.sh
```

### Verify

```bash
/opt/scripts/url-health-monitor.sh --version
/opt/scripts/url-health-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### URLs

```bash
URLS=("https://example.com")
```

Add or remove entries as needed. Each URL is checked independently.

```bash
URLS=(
    "https://api.company.com/health"
    "https://dashboard.company.com"
    "https://internal-service.company.com:8080/status"
)
```

### Check configuration

```bash
TIMEOUT=10
EXPECTED_2XX=0
```

| Variable | Default | Description |
|---|---|---|
| `TIMEOUT` | `10` | Seconds to wait for each HTTP response before giving up. |
| `EXPECTED_2XX` | `0` | Set to `1` to require a 2xx response; 3xx redirects are treated as failures. |

#### Strict 2xx mode

By default the script accepts both 2xx (success) and 3xx (redirect) responses as healthy. Set `EXPECTED_2XX=1` to require a 2xx response — useful for endpoints that should not redirect (REST APIs, health check endpoints):

```bash
EXPECTED_2XX=1
```

With this set, a `301 Moved Permanently` or `302 Found` response is treated as a failure and triggers an alert.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/url-health-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/url-health-monitor.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/url-health-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/url-health-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/url-health-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/url-health-monitor-execution.log` | Every check result per URL. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers:

```bash
HOSTNAME_LABEL="monitor-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/url-health-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/url-health-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/url-health-monitor.status"
```

These are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: url-health-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./url-health-monitor.sh
```

```
https://api.company.com/health                     200
https://dashboard.company.com                      200
https://internal-service.company.com:8080/status   503
ALERT: URLs unhealthy on monitor-prod-01: https://internal-service.company.com:8080/status (503)
```

Healthy URLs appear in green, unhealthy in red (on terminals).

### Dry-run

```bash
./url-health-monitor.sh --dry-run
```

```
Prerequisites:
  curl                         OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     monitor-prod-01
  Timeout:                     10s
  Strict 2xx:                  no
  URLs:                        3 configured
    [1] https://api.company.com/health
    [2] https://dashboard.company.com
    [3] https://internal-service.company.com:8080/status
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  ...

State:
  Currently in ALERT:          https://internal-service.company.com:8080/status
  Maintenance mode:            off
  Last email:                  1842s ago
  Lock directory writable:     OK

https://api.company.com/health                     200
https://dashboard.company.com                      200
https://internal-service.company.com:8080/status   503
[dry-run] would raise alert: https://internal-service.company.com:8080/status (503)
[dry-run] would skip email (rate-limited: last sent 1842s ago; interval 3600s)
```

### Maintenance mode

```bash
./url-health-monitor.sh --maintenance
# Output: Maintenance mode enabled

./url-health-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### HTTP check (HEAD→GET fallback)

For each URL, the script:

1. Sends a `HEAD` request (lighter, no response body downloaded).
2. If the server returns `405 Method Not Allowed`, retries with a full `GET` request.
3. Returns `000` on connection failure, DNS failure, or timeout.

This two-step approach works with servers that reject `HEAD` (some application frameworks do) while still being efficient for well-behaved servers.

### Alert lifecycle (per URL)

Each URL is tracked independently:

```
                    ┌──────────────┐
                    │  not in      │
                    │  ALERT list  │
                    └──────┬───────┘
                           │
              URL returns non-2xx/3xx (first failure)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► add to ALERT list
                    │ (aggregated)│
                    └──────┬──────┘
                           │
              URL still down (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► remains in ALERT list
                    └──────┬──────┘
                           │
              URL returns 2xx/3xx
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► remove from ALERT list
                    └───────────────┘
```

If multiple URLs fail on the same run, a single alert email lists all of them. Recovery emails are sent individually as each URL comes back.

### State file format

`STATUS_FILE` holds a space-separated list of URLs currently in ALERT state:

```
https://api.company.com https://internal.company.com:8080
```

When all URLs are healthy the file is empty or contains only whitespace.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next run that detects new failures, the script checks whether `EMAIL_INTERVAL` seconds have passed. Status tracking is the primary deduplication mechanism; rate-limiting is a safety net for rapid consecutive failures.

Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── url-health-monitor.sh
├── url-health-monitor.status
├── url-health-monitor.email.state
├── url-health-monitor.lock
├── url-health-monitor.maintenance
└── logs/
    ├── url-health-monitor-error.log
    ├── url-health-monitor-error.log.2026-06-01_120000
    ├── url-health-monitor-execution.log
    └── url-health-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [monitor-prod-01] checking 3 URL(s)
2026-06-20 10:00:01 OK https://api.company.com/health (200)
2026-06-20 10:00:02 OK https://dashboard.company.com (200)
2026-06-20 10:00:03 DOWN https://internal-service.company.com:8080/status (503)
2026-06-20 10:00:03 ALERT https://internal-service.company.com:8080/status (503)
2026-06-20 10:00:03 END
2026-06-20 10:15:01 START [monitor-prod-01] checking 3 URL(s)
2026-06-20 10:15:01 OK https://api.company.com/health (200)
2026-06-20 10:15:02 OK https://dashboard.company.com (200)
2026-06-20 10:15:03 DOWN https://internal-service.company.com:8080/status (503)
2026-06-20 10:15:03 RESULT all URLs healthy
2026-06-20 10:15:03 END
```

### Error log

```
2026-06-20 10:00:03 ALERT https://internal-service.company.com:8080/status (503)
2026-06-20 10:00:03 EMAIL sent to ops@example.com
2026-06-20 10:40:01 RECOVERY EMAIL sent for https://internal-service.company.com:8080/status to ops@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Archived copies older than the retention window are deleted. Self-contained — no dependency on `logrotate`.

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
STATUS_FILE="/tmp/url-health-monitor.status"
STATE_FILE="/tmp/url-health-monitor.email.state"
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
  name: url-health-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: url-health-monitor
            image: alpine/bash
            command: ["/scripts/url-health-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
*/5 * * * * /opt/scripts/url-health-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

### Checkmk (local check)

```bash
cp url-health-monitor.sh /usr/lib/check_mk_agent/local/url-health-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add Prometheus metrics inside the check loop:

```bash
echo "url_health{host=\"${HOST_ID}\",url=\"${url}\"} $(is_healthy "$code" && echo 1 || echo 0)" \
    >> /var/lib/node_exporter/url-health.prom
```

### systemd timer

```ini
# /etc/systemd/system/url-health-monitor.service
[Unit]
Description=URL health monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/url-health-monitor.sh
```

```ini
# /etc/systemd/system/url-health-monitor.timer
[Unit]
Description=Run URL health monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now url-health-monitor.timer
```

---

## Use cases

### API endpoint monitoring

Monitor REST API health endpoints across environments:

```bash
URLS=(
    "https://api.company.com/health"
    "https://api-staging.company.com/health"
)
EXPECTED_2XX=1       # health endpoints must return 200, not a redirect
ALERT_EMAIL="api-ops@company.com"
EMAIL_INTERVAL="900" # alert every 15 minutes while down
```

### Internal service monitoring

Monitor internal services that should not be publicly accessible — useful for confirming that services are up from the monitoring host's perspective:

```bash
URLS=(
    "https://internal-dashboard.company.com"
    "https://metrics.company.com:9090"
    "http://legacy-app.company.com:8080/status"
)
ALERT_EMAIL="infra@company.com"
```

### Platform endpoint checks

Monitor multiple WebLogic-fronted application endpoints:

```bash
URLS=(
    "https://dummy.company.com/app/health"
    "https://dummy.company.com/api/ping"
    "https://dummy-staging.company.com/app/health"
)
HOSTNAME_LABEL="dummy-monitor-prod"
ALERT_EMAIL="dummy-ops@company.com"
TIMEOUT=15   # allow extra time for start
```

### Container / sidecar check

```bash
URLS=("http://localhost:8080/actuator/health")
HOSTNAME_LABEL="k8s-app-prod-03"
EXPECTED_2XX=1
ERROR_LOG=""
EXECUTION_LOG=""
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `URLS` | `("https://example.com")` | Array of URLs to check. |
| `TIMEOUT` | `10` | Seconds before a request times out. |
| `EXPECTED_2XX` | `0` | Set to `1` to reject 3xx redirects. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/url-health-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/url-health-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/url-health-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/url-health-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/url-health-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/url-health-monitor.status` | Tracks URLs currently in ALERT state. |

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