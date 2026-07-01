# disk-trend-analyzer.py

disk-trend-analyzer.py                                                   # Reads disk usage history from a JSON file, runs per-filesystem linear    # regression (pure Python stdlib), and estimates when each filesystem will # reach 100%. Appends the current df snapshot to history on every run.     # Alerts when ETA <= ALERT_DAYS or current usage > DISK_THRESHOLD.         #.

---

## Features

- **JSON output** — a single machine-readable document on stdout (`status`, `data`, `alerts`, `duration_seconds`), ready for a monitoring pipeline or `jq`.
- **Status tracking** — alerts once when a problem appears, stays silent while it persists, and sends a recovery email when it clears.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(2)`, with a graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the configuration, the current state, and whether the script is running as root, without performing any work.
- **Monitoring integration** — the JSON envelope and `alert()` seam plug into Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels and graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live at the top of the script; cron entries stay clean.
- **Standard library only** — no `pip install`, no virtualenv; runs on any Python 3.6+.
- **Distro-agnostic** — no package manager and no distro-specific paths beyond the `/proc` filesystem.

---

## Requirements

- **Python 3.6+** (standard library only — no third-party packages).
- **A Linux `/proc` filesystem** (standard on all distributions and containers).

Optional (the script warns and continues without them):

- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).

External tools this script may call (all optional; degrade gracefully):

- **`df`** — used by this script when available; missing tools degrade the affected check gracefully.

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-sysadmin-toolkit.git
cd linux-sysadmin-toolkit/python/disk-trend-analyzer

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-sysadmin-toolkit/main/python/disk-trend-analyzer/disk-trend-analyzer.py \
     -o /opt/scripts/disk-trend-analyzer.py
```

### Manual copy

```bash
cp disk-trend-analyzer.py /opt/scripts/disk-trend-analyzer.py
chmod +x /opt/scripts/disk-trend-analyzer.py
```

### Verify

```bash
python3 /opt/scripts/disk-trend-analyzer.py --version
python3 /opt/scripts/disk-trend-analyzer.py --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives
below a clearly marked separator line (`no changes needed past this line`) — you never need to edit
anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script
once; cron entries stay clean.

### History

```python
HISTORY_FILE = os.path.join(SCRIPT_DIR, "disk-trend-history.json")
MAX_HISTORY = 720
```

| Variable | Default | Description |
|---|---|---|
| `HISTORY_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-history.json")` | — |
| `MAX_HISTORY` | `720` | maximum data points kept per mount (720 x 5min = 2.5d) |

### Thresholds

```python
ALERT_DAYS = 7
DISK_THRESHOLD = 90.0
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_DAYS` | `7` | alert when filesystem will fill within this many days |
| `DISK_THRESHOLD` | `90.0` | also alert when current usage exceeds this percent |

### E-Mail

```python
ALERT_EMAIL = ""
EMAIL_INTERVAL = 3600
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` | "ops@example.com" or space-separated list |
| `EMAIL_INTERVAL` | `3600` | seconds between alert emails |

### Logging

```python
LOG_RETENTION_DAYS = 14
```

| Variable | Default | Description |
|---|---|---|
| `LOG_RETENTION_DAYS` | `14` | delete .log files older than this; 0 = keep forever |

### Host

```python
HOSTNAME_LABEL = ""
```

| Variable | Default | Description |
|---|---|---|
| `HOSTNAME_LABEL` | `""` | override auto-detected hostname |

### Maintenance

```python
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.maintenance")
```

| Variable | Default | Description |
|---|---|---|
| `MAINTENANCE_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.maintenance")` | — |

### Locking

```python
LOCK_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.lock")
```

| Variable | Default | Description |
|---|---|---|
| `LOCK_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.lock")` | — |

### Status

```python
STATUS_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.status")
```

| Variable | Default | Description |
|---|---|---|
| `STATUS_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.status")` | — |

### State

```python
STATE_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.email.state")
```

| Variable | Default | Description |
|---|---|---|
| `STATE_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.email.state")` | — |

---

## Usage

```
Usage: disk-trend-analyzer.py [--dry-run] [--maintenance] [--version]

Options:
  --dry-run       Show configuration, prerequisites, and state without running
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
```

### Basic run

```bash
python3 disk-trend-analyzer.py
```

Output is a JSON document on stdout:

```json
{
  "timestamp": "2026-06-20T08:00:00Z",
  "host": "app-prod-01",
  "script": "disk-trend-analyzer",
  "version": "0.1",
  "status": "OK",
  "data": { "...": "script-specific results" },
  "alerts": [],
  "duration_seconds": 0.12
}
```

`status` is `OK`, `ALERT`, or `ERROR`; the `alerts` array lists any conditions that fired.

### Dry-run

```bash
python3 disk-trend-analyzer.py --dry-run
```

Prints the active configuration, the current status, whether the process is running as root, and the
time since the last email — then exits without doing any work or sending anything.

### Maintenance mode

```bash
# Enable (suppresses all alerts).
python3 disk-trend-analyzer.py --maintenance
# Output: {"maintenance": "enabled"}

# Disable (alerts resume on next run).
python3 disk-trend-analyzer.py --maintenance
# Output: {"maintenance": "disabled"}
```

---

## How it works

disk-trend-analyzer.py                                                   # Reads disk usage history from a JSON file, runs per-filesystem linear    # regression (pure Python stdlib), and estimates when each filesystem will # reach 100%. Appends the current df snapshot to history on every run.     # Alerts when ETA <= ALERT_DAYS or current usage > DISK_THRESHOLD.         #.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
                 a check crosses its threshold
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
                 still over threshold (next runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► exit code 1, no repeat email
                    └──────┬──────┘
                           │
                 back within threshold
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Exit codes

| Exit code | Meaning |
|---|---|
| `0` | Completed with no alerts (`status: OK`), or the dry-run/maintenance/version paths. |
| `0` | Another instance already holds the lock (silent exit to avoid overlap). |
| `1` | One or more alert conditions fired (`status: ALERT`). |
| `2` | An unhandled error occurred (`status: ERROR`); details are in the `alerts` array. |

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next alert (when
transitioning from OK to ALERT), the script checks whether `EMAIL_INTERVAL` seconds have passed. This
is a safety net; status tracking is the primary deduplication mechanism. Recovery emails are never
rate-limited.

---

## Logging

The script writes two optional logs next to itself:

```
disk-trend-analyzer/
├── disk-trend-analyzer.py
├── disk-trend-analyzer.status          # OK / ALERT state
├── disk-trend-analyzer.email.state     # last-email timestamp
├── disk-trend-analyzer.lock            # flock instance lock
├── disk-trend-analyzer.maintenance     # present while maintenance mode is on
├── disk-trend-analyzer-execution.log   # every run (START / END)
└── disk-trend-analyzer-error.log       # alerts, emails, and recoveries only
```

`LOG_RETENTION_DAYS` prunes `.log` files older than the window (default 14 days; `0` = keep forever).

---

## Integration

### Container usage (Kubernetes / Docker)

Set `HOSTNAME_LABEL` to a meaningful name since the container hostname is usually an auto-generated ID:

```python
HOSTNAME_LABEL = "app-prod-01"
```

On read-only container filesystems, point the state files at a writable volume:

```python
MAINTENANCE_FILE = "/tmp/disk-trend-analyzer.maintenance"
LOCK_FILE        = "/tmp/disk-trend-analyzer.lock"
STATUS_FILE      = "/tmp/disk-trend-analyzer.status"
STATE_FILE       = "/tmp/disk-trend-analyzer.email.state"
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: disk-trend-analyzer
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: disk-trend-analyzer
            image: python:3-slim
            command: ["python3", "/scripts/disk-trend-analyzer.py"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```

### Cron

```cron
*/5 * * * * /usr/bin/python3 /opt/scripts/disk-trend-analyzer.py >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/disk-trend-analyzer.service
[Unit]
Description=disk-trend-analyzer check

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/scripts/disk-trend-analyzer.py
```

```ini
# /etc/systemd/system/disk-trend-analyzer.timer
[Unit]
Description=Run disk-trend-analyzer every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now disk-trend-analyzer.timer
```

### Checkmk (local check)

The JSON output maps directly onto a Checkmk local check; wrap it in a small adapter that emits the
Checkmk status line, or store the JSON for a piggyback check.

### Grafana / Prometheus (textfile collector)

Convert the JSON `status`/`data` into a metric written to the node-exporter textfile directory:

```bash
python3 /opt/scripts/disk-trend-analyzer.py \
  | jq -r '"disk-trend-analyzer_status{host=\"" + .host + "\"} " + (if .status=="OK" then "0" else "1" end)' \
  > /var/lib/node_exporter/disk-trend-analyzer.prom
```

---

## Use cases

### Scheduled health check

Run every few minutes from cron or a systemd timer to catch problems early and email the on-call team:

```python
ALERT_EMAIL = "ops@company.com infra@company.com"
HOSTNAME_LABEL = "app-prod-01"
```

### Monitoring pipeline feed

Collect the JSON on a schedule and forward it to your metrics/observability stack; the exit code
(`0`/`1`/`2`) doubles as a simple pass/alert/error signal for a wrapping job.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `HISTORY_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-history.json")` | — |
| `MAX_HISTORY` | `720` | maximum data points kept per mount (720 x 5min = 2.5d) |
| `ALERT_DAYS` | `7` | alert when filesystem will fill within this many days |
| `DISK_THRESHOLD` | `90.0` | also alert when current usage exceeds this percent |
| `ALERT_EMAIL` | `""` | "ops@example.com" or space-separated list |
| `EMAIL_INTERVAL` | `3600` | seconds between alert emails |
| `LOG_RETENTION_DAYS` | `14` | delete .log files older than this; 0 = keep forever |
| `HOSTNAME_LABEL` | `""` | override auto-detected hostname |
| `MAINTENANCE_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.maintenance")` | — |
| `LOCK_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.lock")` | — |
| `STATUS_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.status")` | — |
| `STATE_FILE` | `os.path.join(SCRIPT_DIR, "disk-trend-analyzer.email.state")` | — |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Show configuration, prerequisites, privilege, and state; perform nothing. |
| `--maintenance` | Toggle maintenance mode on/off. Alerts are suppressed while active. |
| `--version` | Print version and exit. |

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
