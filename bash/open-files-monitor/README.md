# open-files-monitor.sh

Monitor system-wide open file descriptors against the kernel maximum.

---

## Purpose

The first and third fields of `/proc/sys/fs/file-nr` give allocated and maximum file descriptors. The script computes the usage percentage in `awk` and alerts when it crosses `THRESHOLD`, optionally attaching the top FD-consuming processes from `lsof`.

---

## Features

- **Kernel-direct measurement from `/proc/sys/fs/file-nr` — no external binary.**
- **Optional per-process FD breakdown via `lsof` in alert emails.**
- **Status-aware alerting with recovery email and rate-limiting.**
- **Maintenance mode, locking, structured logging with rotation.**
- **Email alerts with rate-limiting** — optional `mail(1)` notifications, throttled to `EMAIL_INTERVAL`.
- **Distro-agnostic** — no package-manager assumptions; graceful degradation when optional tools are absent.
- **Self-contained configuration** — all settings live at the top of the script, above the
  `no changes needed past this line` separator. Cron entries stay clean.

---

## Requirements

- **Bash 4.x+**
- **Linux** with the `/proc` (and where noted, `/sys`) filesystem.

Dependencies:

- `/proc/sys/fs/file-nr` — required (standard on Linux)
- `awk` — required
- `lsof` — optional (per-process breakdown in alerts)
- `mail` / `flock` / `find` — optional

---

## Installation

```bash
cp open-files-monitor.sh /opt/scripts/open-files-monitor.sh
chmod +x /opt/scripts/open-files-monitor.sh
/opt/scripts/open-files-monitor.sh --version
/opt/scripts/open-files-monitor.sh --dry-run
```

---

## Usage

```
Usage: open-files-monitor.sh [--dry-run] [--maintenance] [--version] [--help]
```

### Basic run

```bash
./open-files-monitor.sh
```

### Dry-run (check prerequisites and preview actions)

```bash
./open-files-monitor.sh --dry-run
```

The dry-run output lists every dependency (OK / MISSING), the active configuration, and the current
runtime state, then previews the alert that *would* be sent — without sending anything or changing state.

### Maintenance mode (suppress alerts)

```bash
./open-files-monitor.sh --maintenance   # toggle on/off
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. Script-specific settings:

| Variable | Default | Description |
|---|---|---|
| `THRESHOLD` | `80` | Alert when allocated FDs exceed this percent of fs.file-max. |

Common settings shared by every script in this toolkit:

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Minimum seconds between alert emails. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory (auto-created). |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs; `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto)* | Custom hostname for alerts/logs. |

---

## Scheduling

### Cron

```cron
*/5 * * * * /opt/scripts/open-files-monitor.sh >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/open-files-monitor.service
[Unit]
Description=open-files-monitor check
[Service]
Type=oneshot
ExecStart=/opt/scripts/open-files-monitor.sh
```

```ini
# /etc/systemd/system/open-files-monitor.timer
[Unit]
Description=Run open-files-monitor every 5 minutes
[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```

---

## Logging

Two optional logs are written under `LOG_DIR` (default `<script_dir>/logs/`):

- **execution log** — one line per run (`START` / `RESULT` / `END`).
- **error log** — alerts, emails sent, and recoveries only.

Both are rotated automatically once older than `LOG_RETENTION_DAYS`. If `find` is unavailable, rotation
is silently skipped. Set either log path to `""` to disable it.

---

## Exit codes and expected behavior

| Exit code | Meaning |
|---|---|
| `0` | Normal completion — whether the result was OK **or** an alert was raised. The alert condition is reported on stdout/stderr, emailed (if configured), and logged; the process still exits `0` so cron does not flag it. |
| `0` | Another instance already holds the lock (the run exits silently to avoid overlap). |
| `1` | Usage error (unknown option) or an unrecoverable startup error (`die`). |

**Behavioral notes**

- *Idempotent / status-aware:* the script alerts **once** when the condition appears, stays silent while
  it persists, and sends a single recovery email when it clears (state kept in `open-files-monitor.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports, it
  does not modify the resource it monitors.
- *Graceful degradation:* missing optional tools downgrade features (e.g. no email, no locking) with a
  warning rather than failing the run.

---

## Author

**Filcu Alexandru**

## License

MIT
