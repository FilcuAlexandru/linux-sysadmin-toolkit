# systemd-failed-monitor.sh

Lightweight Bash script that checks for systemd units in the failed state and alerts when any are found. Designed for Linux servers where critical services must stay running and failures need to be caught quickly.

Tracks alert state per unit — alerts fire once when a unit first fails and a recovery notification is sent when it comes back, without repeated emails on every cron cycle.

---

## Features

- **Per-unit state tracking** — alerts once when a unit enters the failed state; stays silent while it remains failed; sends a recovery notification when it recovers.
- **Aggregated alerts** — all newly failed units are reported in a single email rather than one per unit.
- **Color-coded terminal output** — green when no failures, red for each failed unit; automatically suppressed in cron, pipes, and container logs.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Recovery notifications** — sends a single email per unit when it leaves the failed state (not rate-limited).
- **Maintenance mode** — toggle alert suppression for planned downtime with `--maintenance`. State persists across runs.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images, no hard dependencies beyond Bash and `systemctl`.
- **Dry-run mode** — check prerequisites and preview all actions without firing anything.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — works on any Linux distribution running systemd.

---

## Requirements

- **Bash 4.x+** (present on virtually all modern Linux systems).
- **systemd** with `systemctl` available in `$PATH` (required).
- **`mail` command** (optional; only needed for email alerts).
- **A configured MTA/relay** (optional; only needed for email delivery).
- **`find` command** (optional; only needed for log rotation. If missing, rotation is silently skipped).
- **`flock` command** (optional; only needed to prevent overlapping cron runs. If missing, locking is silently skipped).

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/systemd-failed-monitor.sh \
     -o /opt/scripts/systemd-failed-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/systemd-failed-monitor.sh \
     -O /opt/scripts/systemd-failed-monitor.sh
```

### Manual copy

```bash
cp systemd-failed-monitor.sh /opt/scripts/systemd-failed-monitor.sh
```

### Make executable and verify

```bash
chmod +x /opt/scripts/systemd-failed-monitor.sh
/opt/scripts/systemd-failed-monitor.sh --version
/opt/scripts/systemd-failed-monitor.sh --help
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/systemd-failed-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. Recovery emails are not rate-limited. |
| `STATE_FILE` | `<script_dir>/systemd-failed-monitor.email.state` | Stores the timestamp of the last sent alert email. |

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
ERROR_LOG="${LOG_DIR}/systemd-failed-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/systemd-failed-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/systemd-failed-monitor-error.log` | Alerts and errors only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/systemd-failed-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

Logging is fully optional. If the log directory cannot be created or a file cannot be written, the script prints a warning and continues.

To disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

### Host identification

```bash
HOSTNAME_LABEL=""
```

| Variable | Default | Description |
|---|---|---|
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom name used in alerts, emails, and logs. When empty, the system hostname is used. |

Useful in containers or environments where the hostname is not meaningful:

```bash
HOSTNAME_LABEL="app-prod-01"
```

---

## Usage

```
Usage: systemd-failed-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./systemd-failed-monitor.sh
```

No failures:

```
No failed units
```

With failures:

```
Failed units:
  nginx.service
  myapp.service
ALERT: Failed systemd units on app-prod-01: nginx.service myapp.service
```

### Dry-run

Prints a full prerequisites report (tools available, active configuration, current alert state) and then previews every action the script would take — without writing any files, sending any emails, or updating any state.

```bash
./systemd-failed-monitor.sh --dry-run
```

```
Prerequisites:
  systemctl                    OK
  mail                         MISSING (email will not work)
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  E-Mail:                      DISABLED
  Error log:                   /opt/scripts/logs/systemd-failed-monitor-error.log
  Execution log:               /opt/scripts/logs/systemd-failed-monitor-execution.log
  Log retention:               14 days

State:
  Currently in ALERT:          nginx.service
  Maintenance mode:            off
  Last email:                  3542s ago
  Lock directory writable:     OK

Failed units:
  nginx.service
[dry-run] would raise alert: nginx.service
[dry-run] would skip email (rate-limited: last sent 3542s ago; interval 3600s)
```

### Maintenance mode

Toggle alert suppression for planned downtime. The state persists across runs until toggled off.

```bash
# Enable maintenance mode (alerts suppressed).
./systemd-failed-monitor.sh --maintenance
# Maintenance mode enabled

# Disable maintenance mode (alerts resume).
./systemd-failed-monitor.sh --maintenance
# Maintenance mode disabled
```

While maintenance mode is active, the script still checks and logs unit states — only alerting (console and email) is suppressed.

---

## How it works

### Alert flow

Alerts fire once per state transition, not once per cron run. This prevents alert storms during a sustained failure.

```
Query systemctl --state=failed
    │
    ├── No failed units
    │       │
    │       ├── Unit was in ALERT ──── Send recovery email ── Remove from STATUS_FILE
    │       └── Unit was OK      ──── Log "no failed units" ── Exit
    │
    └── Failed units found
            │
            ├── Print list (always)
            │
            ├── Unit is NEW failure  ──── Add to STATUS_FILE ── Fire aggregated alert
            └── Unit already in ALERT ── Log only (no repeat alert)
```

### Status tracking (per unit)

The script stores a space-separated list of unit names currently in ALERT state in `STATUS_FILE`. This controls alert deduplication and recovery detection:

- **New failure**: unit not in `STATUS_FILE` → alert fires, unit added to `STATUS_FILE`.
- **Sustained failure**: unit already in `STATUS_FILE` → silent, no repeated alert.
- **Recovery**: unit was in `STATUS_FILE` but no longer failed → recovery email sent, unit removed from `STATUS_FILE`.

If `STATUS_FILE` is missing or empty, all currently failed units are treated as new failures.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next run, the script checks whether `EMAIL_INTERVAL` seconds have passed. If not, the email is skipped. Console alerts and recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── systemd-failed-monitor.sh
└── logs/
    ├── systemd-failed-monitor-error.log
    ├── systemd-failed-monitor-error.log.2026-06-01_120000
    ├── systemd-failed-monitor-execution.log
    └── systemd-failed-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01]
2026-06-20 10:00:01 RESULT no failed units
2026-06-20 10:00:01 END

2026-06-20 11:00:01 START [app-prod-01]
2026-06-20 11:00:01 RESULT failed: nginx.service myapp.service
2026-06-20 11:00:01 ALERT nginx.service myapp.service
2026-06-20 11:00:01 END

2026-06-20 12:00:01 START [app-prod-01]
2026-06-20 12:00:01 RESULT failed: nginx.service myapp.service
2026-06-20 12:00:01 END

2026-06-20 13:00:01 START [app-prod-01]
2026-06-20 13:00:01 RESULT no failed units
2026-06-20 13:00:01 RECOVERY nginx.service
2026-06-20 13:00:01 RECOVERY myapp.service
2026-06-20 13:00:01 END
```

### Error log

```
2026-06-20 11:00:01 ALERT nginx.service myapp.service
2026-06-20 11:00:01 EMAIL sent to ops@example.com
2026-06-20 13:00:01 RECOVERY EMAIL sent for nginx.service to ops@example.com
2026-06-20 13:00:01 RECOVERY EMAIL sent for myapp.service to ops@example.com
```

### Log rotation

At every run, the script checks each log file:

1. If older than `LOG_RETENTION_DAYS`, rename with a timestamp suffix and start fresh.
2. Delete archived copies older than `LOG_RETENTION_DAYS`.

Self-contained — no dependency on `logrotate`.

| `LOG_RETENTION_DAYS` | Behavior |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

## State files

The script maintains state files next to itself (all paths are configurable):

| File | Variable | Purpose |
|---|---|---|
| `systemd-failed-monitor.status` | `STATUS_FILE` | Space-separated list of unit names currently in ALERT state. Controls deduplication and recovery detection. |
| `systemd-failed-monitor.email.state` | `STATE_FILE` | Unix timestamp of the last sent alert email. Used for rate-limiting. |
| `systemd-failed-monitor.maintenance` | `MAINTENANCE_FILE` | Presence of this file activates maintenance mode. Created/removed by `--maintenance`. |
| `systemd-failed-monitor.lock` | `LOCK_FILE` | `flock(1)` lock file. Prevents overlapping cron runs. |

All state files are best-effort: if they cannot be created or read (e.g. read-only filesystem), the script degrades gracefully and continues.

---

## Integration

### Cron

Edit the script to configure all settings, then add a clean cron entry:

```cron
*/5 * * * * /opt/scripts/systemd-failed-monitor.sh >/dev/null 2>&1
```

To capture output in syslog:

```cron
*/5 * * * * /opt/scripts/systemd-failed-monitor.sh 2>&1 | logger -t systemd-failed-monitor
```

### Checkmk (local check)

Place the script in the Checkmk local checks directory:

```bash
cp systemd-failed-monitor.sh /usr/lib/check_mk_agent/local/systemd-failed-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output. The function is designed as a seam for this purpose.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "systemd_failed_units{host=\"${HOST_ID}\"} ${#newly_failed[@]}" \
    > /var/lib/node_exporter/systemd-failed-monitor.prom
```

### systemd timer

```ini
# /etc/systemd/system/systemd-failed-monitor.service
[Unit]
Description=Systemd failed unit monitor

[Service]
Type=oneshot
ExecStart=/opt/scripts/systemd-failed-monitor.sh
```

```ini
# /etc/systemd/system/systemd-failed-monitor.timer
[Unit]
Description=Run systemd failed unit monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now systemd-failed-monitor.timer
```

---

---

## Use cases

### General infrastructure monitoring

```bash
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
```

Catches any unit failure across the system — services, timers, mounts, sockets — without needing to configure individual process names.

### Combined with process-monitor.sh

`process-monitor.sh` checks whether a process binary is running. `systemd-failed-monitor.sh` checks the systemd unit state. Use both for defence in depth:

- A process might be running but its systemd unit could still be in failed state from a previous crash.
- A unit might be in active state but the process could have been killed outside of systemd.

```cron
*/5 * * * * /opt/scripts/process-monitor.sh          >/dev/null 2>&1
*/5 * * * * /opt/scripts/systemd-failed-monitor.sh   >/dev/null 2>&1
```


---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and current alert state, list currently failed units — without alerting. |
| `--maintenance` | Toggle maintenance mode on/off. Alerts are suppressed while active. |
| `--version` | Print version and exit. |
| `--help` | Print usage information and exit. |


---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. |

## Configuration reference

All variables are set inside the script.

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/systemd-failed-monitor.email.state` | Last alert email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/systemd-failed-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/systemd-failed-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts/logs. |
| `STATUS_FILE` | `<script_dir>/systemd-failed-monitor.status` | Per-unit alert state file. |
| `MAINTENANCE_FILE` | `<script_dir>/systemd-failed-monitor.maintenance` | Maintenance mode marker (auto-managed). |

---

## Author

**Filcu Alexandru**

---

## License

This script is provided as-is for personal and professional use.