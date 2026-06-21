# port-monitor.sh

Lightweight Bash script that checks whether one or more configured TCP/UDP ports are listening and alerts when any of them are not. Tracks state per port — alerts once when a port first stops listening, stays silent while it remains closed, and sends a recovery email when it starts listening again.

---

## Features

- **Per-port status tracking** — alerts once on first failure, stays silent while the port remains closed, recovers once it starts listening again.
- **TCP and UDP support** — each entry is a `proto:port` pair (e.g. `tcp:443`, `udp:53`).
- **Aggregated alerts** — all newly closed ports reported in a single alert email per run.
- **Individual recovery emails** — one recovery email per port as each comes back.
- **Dual source** — uses `ss(8)` as primary; falls back to `netstat(8)` if `ss` is unavailable.
- **Robust address parsing** — handles IPv4 (`0.0.0.0:22`), IPv6 (`[::]:443`), and wildcard (`*:8080`) local addresses.
- **Entry validation** — invalid entries (wrong format) are skipped with a warning instead of crashing.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows all dependencies, the port list, and the current alert state.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — works on any Linux system with `ss` or `netstat`.

---

## Requirements

- **Bash 4.x+**
- **`ss`** (preferred) or **`netstat`** — required for port detection. `ss` is part of `iproute2` (pre-installed on all modern Linux distributions). `netstat` is part of `net-tools` (legacy fallback).

Optional (the script warns and continues without them):

- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for instance locking (`util-linux`).
- **`find`** — for log rotation (`findutils`).

---

## Installation

### From Git (recommended)

```bash
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/port-monitor/port-monitor.sh \
     -o /opt/scripts/port-monitor.sh

wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/port-monitor/port-monitor.sh \
     -O /opt/scripts/port-monitor.sh
```

### Manual copy

```bash
cp port-monitor.sh /opt/scripts/port-monitor.sh
chmod +x /opt/scripts/port-monitor.sh
```

### Verify

```bash
/opt/scripts/port-monitor.sh --version
/opt/scripts/port-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Ports

```bash
PORTS=("tcp:22" "tcp:80" "tcp:443")
```

Each entry is a colon-separated `protocol:port` pair:

- `protocol` — `tcp` or `udp`
- `port` — numeric port number (1–65535)

```bash
PORTS=(
    "tcp:22"    # SSH
    "tcp:80"    # HTTP
    "tcp:443"   # HTTPS
    "tcp:5432"  # PostgreSQL
    "udp:53"    # DNS
)
```

Entries with an invalid format (anything other than `tcp:PORT` or `udp:PORT`) are skipped with a warning — the script does not exit on bad entries.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/port-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/port-monitor.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/port-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/port-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/port-monitor-error.log` | Alerts and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/port-monitor-execution.log` | Every run (start, per-port result, end). `""` = disabled. |
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
MAINTENANCE_FILE="${SCRIPT_DIR}/port-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/port-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/port-monitor.status"
```

These are managed automatically.

---

## Usage

```
Usage: port-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./port-monitor.sh
```

When all ports are listening:

```
tcp:22                   listening
tcp:80                   listening
tcp:443                  listening
tcp:5432                 listening
udp:53                   listening
```

When ports are not listening:

```
tcp:22                   listening
tcp:80                   not listening
tcp:443                  not listening
tcp:5432                 listening
udp:53                   listening
ALERT: Ports not listening on app-prod-01: tcp:80 tcp:443
```

### Dry-run

```bash
./port-monitor.sh --dry-run
```

```
Prerequisites:
  ss (primary)                 OK
  netstat (fallback)           OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Ports:                       5 configured
    [1] tcp:22
    [2] tcp:80
    [3] tcp:443
    [4] tcp:5432
    [5] udp:53
  E-Mail:                      ops@example.com
  ...

State:
  Currently in ALERT:          tcp:80 tcp:443
  Maintenance mode:            off
  Last email:                  1823s ago
  Lock directory writable:     OK
```

### Maintenance mode

```bash
./port-monitor.sh --maintenance
# Output: Maintenance mode enabled

./port-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Port detection

Each port is checked with:

```bash
ss -tnlp | awk -v p="$port" 'NR>1 && $2=="LISTEN" { n=split($5,a,":"); if (a[n]==p) found=1 } END { exit !found }'
```

- `ss -tnlp` — list TCP listening sockets with process info.
- `ss -unlp` — list UDP sockets (UDP has no LISTEN state; any bound socket is considered listening).
- The local address field (`$5`) is split on `:` and the last element is compared to the port number — this handles IPv4 (`0.0.0.0:22`), IPv6 (`[::]:443`), and wildcard (`*:8080`) formats.
- If `ss` is not available, `netstat -tnlp` / `netstat -unlp` is used with identical logic on `$4`.

### Alert lifecycle (per port)

```
                    ┌──────────────┐
                    │  not in      │
                    │  ALERT list  │
                    └──────┬───────┘
                           │
              port not listening (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► add to ALERT list
                    │ (aggregated)│
                    └──────┬──────┘
                           │
              port still not listening (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► remains in ALERT list
                    └──────┬──────┘
                           │
              port listening again
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► remove from ALERT list
                    └───────────────┘
```

### State file format

`STATUS_FILE` holds a space-separated list of `proto:port` entries currently in ALERT state:

```
tcp:80 tcp:443
```

When all ports are listening the file is empty.

### Relationship to process-monitor.sh

`port-monitor.sh` and `process-monitor.sh` are complementary:

- `process-monitor.sh` checks whether the **process binary** is running via `pgrep -x`.
- `port-monitor.sh` checks whether the **port** is actually open and accepting connections.

A process can be running but not yet listening (still starting up), or listening on a different port than expected. Running both provides defence in depth.

---

## Logging

### Directory structure

```
scripts/
├── port-monitor.sh
├── port-monitor.status
├── port-monitor.email.state
├── port-monitor.lock
├── port-monitor.maintenance
└── logs/
    ├── port-monitor-error.log
    └── port-monitor-execution.log
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] checking 5 port(s): tcp:22 tcp:80 tcp:443 tcp:5432 udp:53
2026-06-20 10:00:01 OK tcp:22
2026-06-20 10:00:01 DOWN tcp:80
2026-06-20 10:00:01 DOWN tcp:443
2026-06-20 10:00:01 OK tcp:5432
2026-06-20 10:00:01 OK udp:53
2026-06-20 10:00:01 ALERT tcp:80 tcp:443
2026-06-20 10:00:01 END
```

### Error log

```
2026-06-20 10:00:01 ALERT tcp:80 tcp:443
2026-06-20 10:00:01 EMAIL sent to ops@example.com
2026-06-20 10:10:01 RECOVERY EMAIL sent for tcp:80 to ops@example.com
2026-06-20 10:15:01 RECOVERY EMAIL sent for tcp:443 to ops@example.com
```

---

## Integration

### Cron

```cron
*/5 * * * * /opt/scripts/port-monitor.sh >/dev/null 2>&1
```

### Container usage (Kubernetes / Docker)

When running inside a container, set `HOSTNAME_LABEL` to a meaningful name since the container hostname is typically an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

On read-only container filesystems, point state files to a writable volume:

```bash
STATUS_FILE="/tmp/port-monitor.status"
STATE_FILE="/tmp/port-monitor.email.state"
LOG_DIR="/tmp/logs"
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: port-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: port-monitor
            image: alpine/bash
            command: ["/scripts/port-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```

### Checkmk (local check)

```bash
cp port-monitor.sh /usr/lib/check_mk_agent/local/port-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
for entry in "${PORTS[@]}"; do
    proto="${entry%%:*}"; port="${entry##*:}"
    if is_listening "$proto" "$port"; then state=1; else state=0; fi
    echo "port_listening{host=\"${HOST_ID}\",proto=\"${proto}\",port=\"${port}\"} ${state}"
done > /var/lib/node_exporter/port-monitor.prom
```

### Alongside process-monitor.sh and service-watchdog.sh

Full service stack coverage:

```cron
*/5 * * * * /opt/scripts/process-monitor.sh   >/dev/null 2>&1
*/5 * * * * /opt/scripts/port-monitor.sh      >/dev/null 2>&1
*/5 * * * * /opt/scripts/service-watchdog.sh  >/dev/null 2>&1
```

---

## Use cases

### Web stack

```bash
PORTS=(
    "tcp:80"    # HTTP
    "tcp:443"   # HTTPS
    "tcp:5432"  # PostgreSQL
    "tcp:6379"  # Redis
)
ALERT_EMAIL="ops@company.com"
```

### DNS server

```bash
PORTS=(
    "tcp:53"
    "udp:53"
)
HOSTNAME_LABEL="ns1-prod"
ALERT_EMAIL="infra@company.com"
EMAIL_INTERVAL="900"
```

### Java application server

```bash
PORTS=(
    "tcp:8080"   # HTTP listener
    "tcp:8443"   # HTTPS listener
    "tcp:7001"   # WebLogic admin
)
HOSTNAME_LABEL="wls-prod-01"
ALERT_EMAIL="app-ops@company.com"
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `PORTS` | `("tcp:22" "tcp:80" "tcp:443")` | Array of `proto:port` entries to check. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/port-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/port-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/port-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/port-monitor.maintenance` | Maintenance mode marker. |
| `LOCK_FILE` | `<script_dir>/port-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/port-monitor.status` | Tracks `proto:port` entries in ALERT state. |

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