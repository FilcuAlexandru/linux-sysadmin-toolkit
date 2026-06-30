# entropy-monitor.sh

Monitor available kernel entropy and alert when it runs low.

---

## Purpose

The script reads the integer in `/proc/sys/kernel/random/entropy_avail` and alerts when it drops below `MIN_ENTROPY`, a level at which cryptographic operations may begin to block.

---

## Features

- **Kernel-direct read — no external binary needed for the measurement.**
- **Suggests remediation (haveged / rng-tools) in alert emails.**
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

- `/proc/sys/kernel/random/entropy_avail` — required (standard on Linux)
- `mail` / `flock` / `find` — optional

---

## Installation

```bash
cp entropy-monitor.sh /opt/scripts/entropy-monitor.sh
chmod +x /opt/scripts/entropy-monitor.sh
/opt/scripts/entropy-monitor.sh --version
/opt/scripts/entropy-monitor.sh --dry-run
```

---

## Usage

```
Usage: entropy-monitor.sh [--dry-run] [--maintenance] [--version] [--help]
```

### Basic run

```bash
./entropy-monitor.sh
```

### Dry-run (check prerequisites and preview actions)

```bash
./entropy-monitor.sh --dry-run
```

The dry-run output lists every dependency (OK / MISSING), the active configuration, and the current
runtime state, then previews the alert that *would* be sent — without sending anything or changing state.

### Maintenance mode (suppress alerts)

```bash
./entropy-monitor.sh --maintenance   # toggle on/off
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. Script-specific settings:

| Variable | Default | Description |
|---|---|---|
| `MIN_ENTROPY` | `200` | Alert when available entropy drops below this many bits. |

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
*/5 * * * * /opt/scripts/entropy-monitor.sh >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/entropy-monitor.service
[Unit]
Description=entropy-monitor check
[Service]
Type=oneshot
ExecStart=/opt/scripts/entropy-monitor.sh
```

```ini
# /etc/systemd/system/entropy-monitor.timer
[Unit]
Description=Run entropy-monitor every 5 minutes
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
  it persists, and sends a single recovery email when it clears (state kept in `entropy-monitor.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports, it
  does not modify the resource it monitors.
- *Graceful degradation:* missing optional tools downgrade features (e.g. no email, no locking) with a
  warning rather than failing the run.

---

## Author

**Filcu Alexandru**

## License

MIT
