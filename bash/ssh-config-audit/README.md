# ssh-config-audit.sh

Audit sshd configuration for insecure settings.

---

## Purpose

The script obtains the effective SSH configuration via `sshd -T` (falling back to the config file) and checks for a set of well-known insecure directives, alerting if any are present with hardening recommendations.

---

## Features

- **Uses `sshd -T` for the true effective configuration when available.**
- **Falls back to parsing `sshd_config` with comments stripped.**
- **Flags root login, password auth, empty passwords, protocol 1, X11 forwarding.**
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

- `sshd` (openssh-server) — preferred for effective config
- `awk` — required
- read access to `sshd_config` — fallback
- `mail` / `flock` / `find` — optional

---

## Installation

```bash
cp ssh-config-audit.sh /opt/scripts/ssh-config-audit.sh
chmod +x /opt/scripts/ssh-config-audit.sh
/opt/scripts/ssh-config-audit.sh --version
/opt/scripts/ssh-config-audit.sh --dry-run
```

---

## Usage

```
Usage: ssh-config-audit.sh [--dry-run] [--maintenance] [--version] [--help]
```

### Basic run

```bash
./ssh-config-audit.sh
```

### Dry-run (check prerequisites and preview actions)

```bash
./ssh-config-audit.sh --dry-run
```

The dry-run output lists every dependency (OK / MISSING), the active configuration, and the current
runtime state, then previews the alert that *would* be sent — without sending anything or changing state.

### Maintenance mode (suppress alerts)

```bash
./ssh-config-audit.sh --maintenance   # toggle on/off
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. Script-specific settings:

| Variable | Default | Description |
|---|---|---|
| `SSHD_CONFIG` | `/etc/ssh/sshd_config` | Fallback config path when `sshd -T` is unavailable. |

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
*/5 * * * * /opt/scripts/ssh-config-audit.sh >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/ssh-config-audit.service
[Unit]
Description=ssh-config-audit check
[Service]
Type=oneshot
ExecStart=/opt/scripts/ssh-config-audit.sh
```

```ini
# /etc/systemd/system/ssh-config-audit.timer
[Unit]
Description=Run ssh-config-audit every 5 minutes
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
  it persists, and sends a single recovery email when it clears (state kept in `ssh-config-audit.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports, it
  does not modify the resource it monitors.
- *Graceful degradation:* missing optional tools downgrade features (e.g. no email, no locking) with a
  warning rather than failing the run.

---

## Author

**Filcu Alexandru**

## License

MIT
