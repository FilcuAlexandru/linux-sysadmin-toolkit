# mount-options-audit.py

Audit security-relevant mount options on key mount points.

---

## Purpose

Parses `/proc/mounts` and, for each configured mount point, reports which recommended options are missing. A mount point that is not separately mounted is reported as such.

---

## Features

- **Verifies nosuid/nodev/noexec hardening on key mounts.**
- **Reports separately mounted vs. not-separately-mounted paths.**
- **Pure /proc parsing — no external binary.**
- **Standard library only** — no `pip install` required; runs on any Python 3.6+.
- **JSON output** — machine-readable result on stdout for piping into monitoring systems.
- **Status-aware alerting** — alerts once when a condition appears and emails a recovery when it clears.
- **Email alerts with rate-limiting**, **instance locking** (`flock`), **maintenance mode**, and
  **log rotation** — identical to every script in this toolkit.

---

## Requirements

- **Python 3.6+** (standard library only)
- **Linux** with the `/proc` filesystem

Dependencies (optional unless noted):

- `/proc/mounts` (standard on Linux)
- `mail` command — only needed for email alerts.

---

## Installation

```bash
cp mount-options-audit.py /opt/scripts/mount-options-audit.py
chmod +x /opt/scripts/mount-options-audit.py
python3 /opt/scripts/mount-options-audit.py --version
python3 /opt/scripts/mount-options-audit.py --dry-run
```

---

## Usage

```bash
python3 mount-options-audit.py              # run; prints a JSON result on stdout
python3 mount-options-audit.py --dry-run    # print configuration and state, do nothing
python3 mount-options-audit.py --maintenance # toggle maintenance mode (suppresses alerts)
python3 mount-options-audit.py --version    # print version and exit
```

### Output

On a normal run the script prints a JSON document:

```json
{
  "timestamp": "2026-06-30T10:00:00Z",
  "host": "app-prod-01",
  "script": "mount-options-audit",
  "version": "0.1",
  "status": "OK",
  "data": { ... script-specific ... },
  "alerts": [],
  "duration_seconds": 0.12
}
```

`status` is `OK`, `ALERT`, or `ERROR`. The `alerts` array lists any conditions that fired.

---

## Configuration

Edit the variables at the top of the script (above the *no changes needed past this line* marker).

Script-specific settings:

| Variable | Default | Description |
|---|---|---|
| `RECOMMENDED` | `see script` | Mapping of mount point to required option list. |

Common settings shared by every script in this toolkit:

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Minimum seconds between alert emails. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep `.log` files; `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto)* | Custom hostname for alerts/logs. |

---

## Scheduling

### Cron

```cron
*/5 * * * * /usr/bin/python3 /opt/scripts/mount-options-audit.py >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/mount-options-audit.service
[Unit]
Description=mount-options-audit check
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/scripts/mount-options-audit.py
```

```ini
# /etc/systemd/system/mount-options-audit.timer
[Unit]
Description=Run mount-options-audit every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

---

## Exit codes and expected behavior

| Exit code | Meaning |
|---|---|
| `0` | Completed with no alerts (`status: OK`), **or** the dry-run/maintenance/version paths. |
| `0` | Another instance already holds the lock (silent exit to avoid overlap). |
| `1` | Completed but one or more alert conditions fired (`status: ALERT`). |
| `2` | An unhandled error occurred (`status: ERROR`); details are in the `alerts` array and error log. |

**Behavioral notes**

- *Status-aware:* alerts fire once on transition into the alert state and a recovery email is sent once
  when the condition clears (state in `mount-options-audit.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports.
- *Graceful degradation:* missing optional tools downgrade features rather than failing the run; a
  genuinely unexpected error is reported as `status: ERROR` with exit code `2`.

---

## Author

**Filcu Alexandru**

## License

MIT
