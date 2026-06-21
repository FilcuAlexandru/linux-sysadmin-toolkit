# swap-monitor.sh

Lightweight Bash script that monitors swap usage and alerts when it exceeds a configurable threshold. Reads directly from `/proc/meminfo` for accurate, locale-independent measurements with no external binary required. Handles systems with no swap gracefully — reports and exits cleanly without error.

---

## Features

- **Kernel-first measurement** — reads `SwapTotal` and `SwapFree` from `/proc/meminfo`; falls back to `free -m` if `/proc/meminfo` is unavailable.
- **No-swap handling** — systems with no swap configured (containers, some cloud VMs) are detected and reported cleanly as `Swap Usage: none configured` with exit code 0.
- **Status tracking** — alerts once when swap goes above the threshold, stays silent while it remains high, and sends a recovery email when it drops back below.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency and the current runtime state before previewing actions.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems, and clean no-swap handling.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux kernel with `/proc` mounted** (standard on all distributions and containers)

Optional (the script warns and continues without them):

- **`free`** — fallback swap source when `/proc/meminfo` is unavailable.
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

curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/swap-monitor.sh \
     -o /opt/scripts/swap-monitor.sh

wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/swap-monitor.sh \
     -O /opt/scripts/swap-monitor.sh
```

### Manual copy

```bash
cp swap-monitor.sh /opt/scripts/swap-monitor.sh
chmod +x /opt/scripts/swap-monitor.sh
```

### Verify

```bash
/opt/scripts/swap-monitor.sh --version
/opt/scripts/swap-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line.

### Threshold

```bash
THRESHOLD=80
```

Alert fires when swap usage exceeds this percentage. Has no effect on systems with no swap configured.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/swap-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/swap-monitor.email.state` | Stores the timestamp of the last sent email. |

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
ERROR_LOG="${LOG_DIR}/swap-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/swap-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/swap-monitor-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/swap-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

```bash
HOSTNAME_LABEL="db-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/swap-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/swap-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/swap-monitor.status"
```

---

## Usage

```
Usage: swap-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./swap-monitor.sh
```

No swap configured:

```
Swap Usage: none configured
```

Below threshold:

```
Swap Usage: 0.42/2.00GB (21.00%)
```

Above threshold:

```
Swap Usage: 1.60/2.00GB (80.00%)
ALERT: Swap usage above 80% on db-prod-01: 80.00% (1.60/2.00GB)
```

### Dry-run

```bash
./swap-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/meminfo                OK
  free                         OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     db-prod-01
  Threshold:                   80%
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  ...

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

Swap Usage: 0.42/2.00GB (21.00%)
```

### Maintenance mode

```bash
./swap-monitor.sh --maintenance
# Output: Maintenance mode enabled

./swap-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Swap measurement (source priority)

1. **`/proc/meminfo`** (preferred) — reads `SwapTotal` and `SwapFree` directly from the kernel:

   ```
   used_kb = SwapTotal - SwapFree
   pct     = used_kb / SwapTotal * 100
   ```

   No external binary needed. Available on every Linux system and inside every standard container.

2. **`free -m`** (fallback) — parses the `Swap:` line (NR==3). Used only when `/proc/meminfo` is not readable.

### No-swap handling

When `SwapTotal` is `0` in `/proc/meminfo` (or `free -m` reports 0 total), the `hasswap` flag is set to `0`. The script prints `Swap Usage: none configured` and exits with code 0 — no alert, no status change, no email. This is normal and expected on:

- Containers (Docker, Kubernetes pods) where swap is typically disabled.
- Cloud VMs configured without swap.
- Systems where swap has been intentionally disabled.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              swap > THRESHOLD (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              swap still > THRESHOLD (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              swap <= THRESHOLD
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

---

## Logging

### Directory structure

```
scripts/
├── swap-monitor.sh
├── swap-monitor.status
├── swap-monitor.email.state
├── swap-monitor.lock
├── swap-monitor.maintenance
└── logs/
    ├── swap-monitor-error.log
    ├── swap-monitor-execution.log
```

### Execution log

```
2026-06-20 10:00:01 START [db-prod-01] threshold=80%
2026-06-20 10:00:01 RESULT 21.00% used=0.42GB total=2.00GB (ok)
2026-06-20 10:00:01 END
2026-06-20 10:05:01 START [db-prod-01] threshold=80%
2026-06-20 10:05:01 RESULT 80.00% used=1.60GB total=2.00GB (above threshold)
2026-06-20 10:05:01 END
2026-06-20 10:10:01 START [db-prod-01] threshold=80%
2026-06-20 10:10:01 RESULT 80.00% used=1.60GB total=2.00GB (above threshold)
2026-06-20 10:10:01 Already in ALERT state
2026-06-20 10:10:01 END
```

No-swap systems:

```
2026-06-20 10:00:01 START [container-prod] threshold=80%
2026-06-20 10:00:01 RESULT no swap configured
2026-06-20 10:00:01 END
```

### Error log

```
2026-06-20 10:05:01 ALERT 80.00% (1.60/2.00GB)
2026-06-20 10:05:01 EMAIL sent to ops@example.com
2026-06-20 10:45:01 RECOVERY EMAIL sent to ops@example.com
```

---

## Integration

### Cron

```cron
*/5 * * * * /opt/scripts/swap-monitor.sh >/dev/null 2>&1
```

### Using alongside memory-usage-monitor.sh

Swap and memory monitors are complementary:

- `memory-usage-monitor.sh` — monitors RAM usage. High RAM → applications are consuming physical memory.
- `swap-monitor.sh` — monitors swap. High swap → system is paging, which typically means RAM is also exhausted and performance is degrading.

```cron
*/5 * * * * /opt/scripts/memory-usage-monitor.sh >/dev/null 2>&1
*/5 * * * * /opt/scripts/swap-monitor.sh          >/dev/null 2>&1
```

A swap alert almost always follows a memory alert. The two together give the full picture of memory pressure.

### Checkmk (local check)

```bash
cp swap-monitor.sh /usr/lib/check_mk_agent/local/swap-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
echo "swap_usage_percent{host=\"${HOST_ID}\"} ${pct}" \
    > /var/lib/node_exporter/swap-usage.prom
```

### systemd timer

```ini
# /etc/systemd/system/swap-monitor.service
[Unit]
Description=Swap usage monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/swap-monitor.sh
```

```ini
# /etc/systemd/system/swap-monitor.timer
[Unit]
Description=Run swap monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### Database server with swap

Database workloads (PostgreSQL, MySQL) can push systems into swap under heavy query load. Alert early:

```bash
THRESHOLD=50   # database performance degrades significantly when swap is used
ALERT_EMAIL="dba@company.com ops@company.com"
HOSTNAME_LABEL="db-prod-01"
```

### General-purpose server

```bash
THRESHOLD=80
ALERT_EMAIL="ops@company.com"
```

### Container environment (no swap)

The script handles this automatically. No configuration needed — it detects and reports `none configured` and exits cleanly. Safe to run in cron on all hosts regardless of swap configuration.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD` | `80` | Alert when swap usage exceeds this percentage. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/swap-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/swap-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/swap-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/swap-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/swap-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/swap-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview actions without performing them. |
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