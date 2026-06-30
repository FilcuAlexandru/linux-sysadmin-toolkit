# interface-link-monitor.sh

Monitor network interface link state (up/down).

---

## Purpose

The script reads `/sys/class/net/<iface>/operstate` for each monitored interface. A state other than `up` or `unknown` is treated as a link failure and triggers an alert listing the affected interfaces.

---

## Features

- **Reads link state directly from sysfs `operstate`.**
- **Auto-detects physical interfaces, skipping loopback and virtual devices.**
- **Treats `unknown` (common for virtual NICs) as up to avoid false alarms.**
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

- `/sys/class/net` — required (standard on Linux)
- `mail` / `flock` / `find` — optional

---

## Installation

```bash
cp interface-link-monitor.sh /opt/scripts/interface-link-monitor.sh
chmod +x /opt/scripts/interface-link-monitor.sh
/opt/scripts/interface-link-monitor.sh --version
/opt/scripts/interface-link-monitor.sh --dry-run
```

---

## Usage

```
Usage: interface-link-monitor.sh [--dry-run] [--maintenance] [--version] [--help]
```

### Basic run

```bash
./interface-link-monitor.sh
```

### Dry-run (check prerequisites and preview actions)

```bash
./interface-link-monitor.sh --dry-run
```

The dry-run output lists every dependency (OK / MISSING), the active configuration, and the current
runtime state, then previews the alert that *would* be sent — without sending anything or changing state.

### Maintenance mode (suppress alerts)

```bash
./interface-link-monitor.sh --maintenance   # toggle on/off
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. Script-specific settings:

| Variable | Default | Description |
|---|---|---|
| `INTERFACES` | `"" (auto)` | Space-separated interface names, or empty to auto-detect physical NICs. |

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
*/5 * * * * /opt/scripts/interface-link-monitor.sh >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/interface-link-monitor.service
[Unit]
Description=interface-link-monitor check
[Service]
Type=oneshot
ExecStart=/opt/scripts/interface-link-monitor.sh
```

```ini
# /etc/systemd/system/interface-link-monitor.timer
[Unit]
Description=Run interface-link-monitor every 5 minutes
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
  it persists, and sends a single recovery email when it clears (state kept in `interface-link-monitor.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports, it
  does not modify the resource it monitors.
- *Graceful degradation:* missing optional tools downgrade features (e.g. no email, no locking) with a
  warning rather than failing the run.

---

## Author

**Filcu Alexandru**

## License

MIT
