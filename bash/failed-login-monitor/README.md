# failed-login-monitor.sh

Lightweight Bash script that counts failed SSH login attempts within a configurable time window and alerts when the count exceeds a threshold. Designed for simple brute-force detection without requiring fail2ban or any external tool. Reads from `journalctl` (systemd) with a fallback to `/var/log/auth.log` (syslog systems). Alert emails include the top offending source IPs.

---

## Features

- **Time-windowed counting** — counts failed attempts in the last `WINDOW_MINUTES` minutes (default: 60), not total lifetime counts.
- **Top offender IPs** — alert emails include the top 5 source IPs ranked by attempt count, ready for manual ban or fail2ban correlation.
- **Dual source** — uses `journalctl _COMM=sshd` as primary; falls back to `/var/log/auth.log` on syslog-based systems.
- **Status tracking** — alerts once when the count exceeds the threshold, stays silent while it remains above, and sends a recovery email when it drops back down.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows source availability, the current count, and the effective threshold.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.

---

## Requirements

- **Bash 4.x+**
- **`journalctl`** (preferred) or **`/var/log/auth.log`** (fallback) — at least one must be available.

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

curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/failed-login-monitor/failed-login-monitor.sh \
     -o /opt/scripts/failed-login-monitor.sh

wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/failed-login-monitor/failed-login-monitor.sh \
     -O /opt/scripts/failed-login-monitor.sh
```

### Manual copy

```bash
cp failed-login-monitor.sh /opt/scripts/failed-login-monitor.sh
chmod +x /opt/scripts/failed-login-monitor.sh
```

### Verify

```bash
/opt/scripts/failed-login-monitor.sh --version
/opt/scripts/failed-login-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Detection

```bash
WINDOW_MINUTES="60"
THRESHOLD="10"
AUTH_LOG="/var/log/auth.log"
```

| Variable | Default | Description |
|---|---|---|
| `WINDOW_MINUTES` | `60` | Look back this many minutes when counting failed attempts. |
| `THRESHOLD` | `10` | Alert when the failed attempt count in the window exceeds this value. |
| `AUTH_LOG` | `/var/log/auth.log` | Fallback log file when `journalctl` is unavailable. `""` = disable fallback. |

#### Tuning guidance

| Environment | `WINDOW_MINUTES` | `THRESHOLD` | Notes |
|---|---|---|---|
| Public internet server | `60` | `10` | Default. Alert on moderate brute force. |
| High-security / minimal access | `60` | `3` | Alert on any suspicious pattern. |
| High-traffic jump host | `60` | `50` | Reduce noise from legitimate automation. |
| Short burst detection | `5` | `5` | Alert on rapid fire within 5 minutes. |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/failed-login-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/failed-login-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com security@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/failed-login-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/failed-login-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/failed-login-monitor-error.log` | Alerts and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/failed-login-monitor-execution.log` | Every run (count, result). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

```bash
HOSTNAME_LABEL="jumphost-prod"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/failed-login-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/failed-login-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/failed-login-monitor.status"
```

These are managed automatically.

---

## Usage

```
Usage: failed-login-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./failed-login-monitor.sh
```

Below threshold:

```
Failed SSH logins: 3 in last 60 min (threshold: 10)
```

Above threshold:

```
Failed SSH logins: 47 in last 60 min (threshold: 10)
ALERT: High SSH failure rate on jumphost-prod: 47 failed attempts in last 60min (threshold: 10)
Top source IPs:
     23  192.168.1.100
     12  10.0.0.55
      8  172.16.0.3
      3  203.0.113.42
      1  198.51.100.7
```

### Dry-run

```bash
./failed-login-monitor.sh --dry-run
```

```
Prerequisites:
  journalctl (primary)         OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     jumphost-prod
  Window:                      60 min
  Threshold:                   10
  Auth log fallback:           /var/log/auth.log
  E-Mail:                      ops@example.com
  ...

State:
  Current status:              ALERT
  Maintenance mode:            off
  Last email:                  1842s ago
  Lock directory writable:     OK

Failed SSH logins: 47 in last 60 min (threshold: 10)
[dry-run] would raise alert: 47 failed attempts in last 60min (threshold: 10)
[dry-run] would skip email (rate-limited: last sent 1842s ago; interval 3600s)
```

### Maintenance mode

```bash
./failed-login-monitor.sh --maintenance
# Output: Maintenance mode enabled

./failed-login-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Source priority

```
journalctl _COMM=sshd --since="60 minutes ago"
    │
    │  filters lines containing:
    │  "Failed" | "Invalid" | "authentication failure"
    │
    └── count_failed_logins() returns the count
```

If `journalctl` is unavailable (non-systemd systems or containers without journal access):

```
/var/log/auth.log
    │
    │  grep "Failed password" | "Invalid user" | "authentication failure"
    │  awk filters by parsed timestamp (within the window)
    │
    └── count_failed_logins() returns the count
```

If neither source is available, the count defaults to `0` — the script never dies on unavailable log sources.

### Top offender extraction

When the threshold is exceeded, `top_offenders()` scans the same source for `from <IP>` patterns, counts occurrences per IP, and returns the top 5 sorted by descending count. This list is included in the alert email body.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              count > THRESHOLD (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    │ + top IPs   │
                    └──────┬──────┘
                           │
              count still > THRESHOLD (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              count <= THRESHOLD
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

Recovery is triggered when the count drops back at or below the threshold. This happens naturally as the sliding window advances past the burst period.

---

## Logging

### Directory structure

```
scripts/
├── failed-login-monitor.sh
├── failed-login-monitor.status
├── failed-login-monitor.email.state
├── failed-login-monitor.lock
├── failed-login-monitor.maintenance
└── logs/
    ├── failed-login-monitor-error.log
    └── failed-login-monitor-execution.log
```

### Execution log

```
2026-06-20 10:00:01 START [jumphost-prod] window=60min threshold=10
2026-06-20 10:00:01 RESULT count=3 threshold=10 window=60min (ok)
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [jumphost-prod] window=60min threshold=10
2026-06-20 10:05:01 RESULT count=47 threshold=10 window=60min (above)
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [jumphost-prod] window=60min threshold=10
2026-06-20 10:10:01 RESULT count=47 threshold=10 window=60min (above)
2026-06-20 10:10:01 Already in ALERT state
2026-06-20 10:10:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT 47 failed attempts in last 60min (threshold: 10)
2026-06-20 10:05:01 EMAIL sent to ops@example.com
2026-06-20 11:10:01 RECOVERY EMAIL sent to ops@example.com
```

---

## Integration

### Cron

```cron
*/5 * * * * /opt/scripts/failed-login-monitor.sh >/dev/null 2>&1
```

### Container usage (Kubernetes / Docker)

When running inside a container, journal access may be unavailable. Set `AUTH_LOG` to a mounted log file:

```bash
AUTH_LOG="/host-logs/auth.log"
HOSTNAME_LABEL="jumphost-prod"
```

Mount the host log directory into the container:

```yaml
volumes:
- name: host-logs
  hostPath:
    path: /var/log
volumeMounts:
- name: host-logs
  mountPath: /host-logs
  readOnly: true
```

On read-only container filesystems, point state files to a writable volume:

```bash
STATUS_FILE="/tmp/failed-login-monitor.status"
STATE_FILE="/tmp/failed-login-monitor.email.state"
LOG_DIR="/tmp/logs"
```

### Checkmk (local check)

```bash
cp failed-login-monitor.sh /usr/lib/check_mk_agent/local/failed-login-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
count=$(count_failed_logins)
echo "ssh_failed_logins{host=\"${HOST_ID}\",window=\"${WINDOW_MINUTES}m\"} ${count}" \
    > /var/lib/node_exporter/failed-logins.prom
```

### Alongside fail2ban

This script and fail2ban are complementary — not alternatives:

- `failed-login-monitor.sh` — detects and **alerts**. Useful when fail2ban is not installed or when you want a second opinion alert channel.
- `fail2ban` — detects and **blocks**. Operates in real time.

Run both: the script alerts your ops team while fail2ban handles automated blocking.

### systemd timer

```ini
# /etc/systemd/system/failed-login-monitor.service
[Unit]
Description=Failed SSH login monitor

[Service]
Type=oneshot
ExecStart=/opt/scripts/failed-login-monitor.sh
```

```ini
# /etc/systemd/system/failed-login-monitor.timer
[Unit]
Description=Run failed login monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### Public internet SSH server

```bash
WINDOW_MINUTES="60"
THRESHOLD="10"
ALERT_EMAIL="security@company.com ops@company.com"
EMAIL_INTERVAL="1800"
```

### High-security jump host

```bash
WINDOW_MINUTES="60"
THRESHOLD="3"
ALERT_EMAIL="security@company.com"
EMAIL_INTERVAL="900"
```

### Short burst detection

Alert on rapid fire within a short window:

```bash
WINDOW_MINUTES="5"
THRESHOLD="5"
ALERT_EMAIL="ops@company.com"
```

### Non-systemd server (syslog)

```bash
AUTH_LOG="/var/log/auth.log"   # already the default
WINDOW_MINUTES="60"
THRESHOLD="10"
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `WINDOW_MINUTES` | `60` | Time window in minutes for counting failed attempts. |
| `THRESHOLD` | `10` | Alert when count exceeds this value. |
| `AUTH_LOG` | `/var/log/auth.log` | Fallback log file. `""` = disabled. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/failed-login-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/failed-login-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/failed-login-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/failed-login-monitor.maintenance` | Maintenance mode marker. |
| `LOCK_FILE` | `<script_dir>/failed-login-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/failed-login-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, display current count and preview actions — without alerting. |
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

This script is provided as-is for personal and professional use. Add your preferred license here (MIT, GPL, etc.).