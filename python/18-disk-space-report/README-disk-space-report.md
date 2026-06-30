# disk-space-report.py

Reports disk usage with ASCII bar charts and trend data. Outputs structured JSON to stdout on every run. Part of the Python SysAdmin Toolkit.

---

## Features

- **JSON output by default** — every run prints structured JSON; no flags needed.
- **Zero external dependencies** — Python 3.6+ standard library only.
- **Status-aware alerting** — alerts once on first breach, silent while above threshold, recovery email when cleared.
- **Email alerts with rate-limiting** — optional `mail(1)` notifications, one per `EMAIL_INTERVAL` seconds, multiple recipients supported.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — `fcntl.flock` prevents overlapping runs; exits silently when locked.
- **Automatic log rotation** — deletes `.log` files older than `LOG_RETENTION_DAYS` on every run.
- **Container-ready** — custom hostname labels; graceful degradation on read-only filesystems.

---

## Requirements

- Python 3.6+
- Linux with `/proc` filesystem mounted
- `mail` command (optional) — for email alerts

---

## Installation

```bash
cp disk-space-report.py /opt/scripts/disk-space-report.py
chmod +x /opt/scripts/disk-space-report.py
python3 /opt/scripts/disk-space-report.py --version
python3 /opt/scripts/disk-space-report.py --dry-run
```

---

## Configuration

All configuration lives at the top of the script, above:

```
# Script logic below; no changes needed past this line.
```

Edit variables above that line only.

---

## Usage

```bash
./disk-space-report.py              # run and output JSON to stdout
./disk-space-report.py --dry-run    # show prerequisites and configuration without running
./disk-space-report.py --maintenance # toggle maintenance mode on/off
./disk-space-report.py --version    # print version and exit
./disk-space-report.py --help       # print help
```

### Output format

All output is JSON on stdout. Exit codes: `0`=OK, `1`=ALERT, `2`=ERROR.

```json
{
  "timestamp": "2026-06-25T10:00:01Z",
  "host":      "app-prod-01",
  "script":    "disk-space-report",
  "version":   "0.1",
  "status":    "OK",
  "data":      { ... },
  "alerts":    [],
  "duration_seconds": 2.14
}
```

---

## How it works

1. Acquires an exclusive lock (`fcntl.flock`) — prevents concurrent runs.
2. Rotates old log files from `SCRIPT_DIR`.
3. Collects all metrics in one pass.
4. Evaluates alerts against configured thresholds.
5. Updates OK/ALERT status and sends email if appropriate.
6. Prints a complete JSON result to stdout.
7. Exits with `0`=OK, `1`=ALERT, or `2`=ERROR.

---

## Logging

Two log files are written to the same directory as the script:

| File | Content |
|---|---|
| `disk-space-report-execution.log` | Every run: start, result, end. |
| `disk-space-report-error.log` | Alerts, recovery emails, and errors only. |

Both are auto-rotated when older than `LOG_RETENTION_DAYS` days.

---

## Integration examples

### Cron (every 5 minutes)

```cron
*/5 * * * * /opt/scripts/disk-space-report.py >> /var/log/disk-space-report.json 2>/dev/null
```

### Pipe to jq

```bash
python3 disk-space-report.py | jq '.data'
python3 disk-space-report.py | jq '.alerts[]'
python3 disk-space-report.py | jq '.status'
```

### Checkmk local check

```bash
cp disk-space-report.py /usr/lib/check_mk_agent/local/disk-space-report.py
```

### Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: disk-space-report
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: disk-space-report
            image: python:3.11-slim
            command: ["python3", "/scripts/disk-space-report.py"]
          restartPolicy: OnFailure
```

---

## Configuration reference

### Standard variables (all scripts)

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` | Space-separated email recipients. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `LOG_RETENTION_DAYS` | `14` | Delete `.log` files older than this many days. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` | Override auto-detected hostname. Useful in containers. |
| `MAINTENANCE_FILE` | auto | Path to maintenance mode marker file. |
| `LOCK_FILE` | auto | Path to instance lock file (flock). |
| `STATUS_FILE` | auto | Persists OK/ALERT status between runs. |
| `STATE_FILE` | auto | Stores last-email timestamp for rate-limiting. |

### Domain-specific variables

| Variable | Description |
|---|---|
| `DISK_THRESHOLD` | See inline comment in script. |
| `WARN_THRESHOLD` | See inline comment in script. |
| `HISTORY_FILE` | See inline comment in script. |
| `BAR_WIDTH` | See inline comment in script. |

---

## CLI reference

| Option | Description |
|---|---|
| *(no flags)* | Run normally and print JSON to stdout. |
| `--dry-run` | Show prerequisites and config without collecting data. |
| `--maintenance` | Toggle maintenance mode on/off. |
| `--version` | Print version and exit. |
| `--help` | Print usage and exit. |

---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. |

---

## Author

Filcu Alexandru

---

## License

MIT — use freely, retain attribution.
