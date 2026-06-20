# file-change-monitor.sh

Lightweight Bash script that watches a directory for filesystem events using `inotifywait` and reports them live. Designed to run continuously as a systemd service. Can generate and install its own unit file.

Unlike the one-shot scripts in this collection, this script runs as a **daemon** — it stays alive indefinitely and reacts to events as they happen.

---

## Features

- **Live event monitoring** — reports `create`, `modify`, `delete`, `moved_to`, and `moved_from` events as they happen, color-coded in the terminal.
- **Configurable alert events** — choose which event types trigger an email alert. Default: delete only. Add create or modify if needed.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Maintenance mode** — toggle with `--maintenance`; suppresses email only while active. Console output always continues.
- **Self-installing systemd unit** — `--print-unit` prints the unit file; `--install-service` writes it and reloads systemd.
- **Structured logging** — optional execution log (every event) and error log (alert events only), with rotation at daemon startup.
- **Prerequisites check** — `--dry-run` shows the status of every dependency and the active configuration before starting the daemon.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on minimal images.
- **Self-contained configuration** — all settings live inside the script; systemd unit and cron entries stay clean.
- **Distro-agnostic** — works on any Linux distribution with `inotifywait` available.

---

## Requirements

- **Bash 4.x+**
- **`inotifywait`** — required; provided by the `inotify-tools` package.

Optional (the script warns and continues without them):

- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for single-instance locking (`util-linux`).
- **`find`** — for log rotation at startup (`findutils`).
- **`systemctl`** — for `--install-service` to reload systemd after installing the unit.

### Installing inotify-tools

```bash
# Debian / Ubuntu
apt install inotify-tools

# RHEL / CentOS / Fedora
dnf install inotify-tools

# SLES / openSUSE
zypper install inotify-tools

# Alpine
apk add inotify-tools

# Gentoo
emerge sys-fs/inotify-tools
```

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/file-change-monitor.sh \
     -o /opt/scripts/file-change-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/file-change-monitor.sh \
     -O /opt/scripts/file-change-monitor.sh
```

### Manual copy

```bash
cp file-change-monitor.sh /opt/scripts/file-change-monitor.sh
chmod +x /opt/scripts/file-change-monitor.sh
```

### Verify

```bash
/opt/scripts/file-change-monitor.sh --version
/opt/scripts/file-change-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Watch configuration

```bash
WATCH_DIR="/path/to/directory"
EVENTS=("create" "modify" "delete")
ALERT_EVENTS=("delete")
SERVICE_PATH="/etc/systemd/system/file-change-monitor.service"
```

| Variable | Default | Description |
|---|---|---|
| `WATCH_DIR` | `/path/to/directory` | Directory to monitor. Must exist when the script starts. |
| `EVENTS` | `("create" "modify" "delete")` | inotify events to watch. Supported: `create` `modify` `delete` `moved_to` `moved_from`. |
| `ALERT_EVENTS` | `("delete")` | Subset of `EVENTS` that trigger an email alert. |
| `SERVICE_PATH` | `/etc/systemd/system/file-change-monitor.service` | Where `--install-service` writes the unit file. |

#### Widening alert events

To alert on any change, not just deletions:

```bash
ALERT_EVENTS=("create" "modify" "delete")
```

To alert only on deletions and moves out of the directory:

```bash
ALERT_EVENTS=("delete" "moved_from")
```

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/file-change-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console output is never rate-limited. |
| `STATE_FILE` | `<script_dir>/file-change-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Rate-limiting note

In a busy directory, delete events can fire dozens of times per minute. `EMAIL_INTERVAL` prevents flooding: only the first alert email within the window is sent. Every event is still printed to the console and logged regardless of the rate limit.

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/file-change-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/file-change-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created at startup. |
| `ERROR_LOG` | `<LOG_DIR>/file-change-monitor-error.log` | Alert events and email actions only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/file-change-monitor-execution.log` | Every filesystem event. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate logs older than this at startup. `0` = keep forever. |

**Note on log rotation:** because this script runs continuously, rotation only happens at startup (when the daemon starts or restarts). For production use, consider `logrotate` with `copytruncate` for mid-run rotation without restarting the daemon.

To disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers:

```bash
HOSTNAME_LABEL="filewatch-prod-01"
```

### Maintenance mode

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/file-change-monitor.maintenance"
```

Managed automatically by `--maintenance`. Override the path if the script directory is read-only.

---

## Usage

```
Usage: file-change-monitor.sh [--dry-run] [--print-unit] [--install-service] [--maintenance] [--version] [--help]

Options:
  --dry-run          Watch and print events, but preview alerts instead of sending
  --print-unit       Print the systemd unit file to stdout
  --install-service  Write the unit to SERVICE_PATH and reload systemd
  --maintenance      Toggle maintenance mode (email suppressed; console continues)
  --version          Show version and exit
  --help             Show this help and exit
```

### Basic run (foreground)

```bash
./file-change-monitor.sh
```

```
Watching /opt/app/data for: create modify delete (Ctrl-C to stop)
[2026-06-20 10:00:01] CREATE         /opt/app/data/report.csv
[2026-06-20 10:00:02] MODIFY         /opt/app/data/report.csv
[2026-06-20 10:00:03] DELETE         /opt/app/data/old-report.csv
ALERT: File event on app-prod-01: DELETE /opt/app/data/old-report.csv
```

Create events appear in green, modify in yellow, delete in red (on terminals).

### Dry-run

```bash
./file-change-monitor.sh --dry-run
```

Shows prerequisites and configuration, then watches and prints events — but previews alerts instead of sending them:

```
[2026-06-20 10:00:03] DELETE         /opt/app/data/old-report.csv
[dry-run] would raise alert: DELETE /opt/app/data/old-report.csv
[dry-run] would email: ops@example.com (last sent: never)
```

### Maintenance mode

```bash
# Suppress email alerts (console output continues).
./file-change-monitor.sh --maintenance
# Output: Maintenance mode enabled (email alerts suppressed; console output continues)

# Resume email alerts.
./file-change-monitor.sh --maintenance
# Output: Maintenance mode disabled (email alerts will resume)
```

This is the key difference from other scripts in the collection: maintenance mode suppresses **email only**. Console output always continues, because as a daemon the script must keep reporting events regardless.

### Printing the systemd unit

```bash
./file-change-monitor.sh --print-unit
```

Prints a ready-to-use unit file with the real script path, `WATCH_DIR`, and `ALERT_EMAIL` already embedded:

```ini
# Generated by file-change-monitor.sh 0.1
[Unit]
Description=File change monitor (inotify) for /opt/app/data
After=local-fs.target

[Service]
Type=simple
Environment=WATCH_DIR=/opt/app/data
Environment=ALERT_EMAIL=ops@example.com
ExecStart=/opt/scripts/file-change-monitor.sh
Restart=on-failure
RestartSec=5
User=root
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

### Installing as a systemd service

```bash
# Option 1: install directly (requires write access to /etc/systemd/system/).
sudo ./file-change-monitor.sh --install-service

# Option 2: print and pipe (when running as a non-root user).
./file-change-monitor.sh --print-unit | sudo tee /etc/systemd/system/file-change-monitor.service

# Then enable and start.
sudo systemctl enable --now file-change-monitor.service
sudo systemctl status file-change-monitor.service

# View live events in the journal.
journalctl -u file-change-monitor -f
```

---

## How it works

### Event flow

```
inotifywait -m (monitor mode)
    │
    └── for each event:
            │
            ├── color-code and print to stdout (always)
            ├── log to EXECUTION_LOG (if enabled)
            │
            └── is this event in ALERT_EVENTS?
                    │
                    ├── No  ──── done
                    │
                    └── Yes
                            ├── console ALERT (always)
                            ├── log to ERROR_LOG
                            │
                            └── Email?
                                 ├── ALERT_EMAIL empty ─── skip
                                 ├── mail not found ──────── warn, skip
                                 ├── Maintenance active ──── skip (console alert still sent)
                                 ├── Rate-limited ──────────── skip (notice on stderr)
                                 └── Interval passed ───────── send to all recipients
                                                                └── update STATE_FILE
```

### Daemon vs one-shot

This script behaves differently from the other monitors in this collection:

| | One-shot monitors | file-change-monitor |
|---|---|---|
| Run duration | Seconds | Indefinitely |
| Trigger | Cron / systemd timer | systemd service |
| Status tracking | Per run (OK/ALERT) | Not applicable (each event is unique) |
| Recovery emails | Yes | No |
| Locking on conflict | Exit silently (code 0) | Die with error |
| Log rotation | Every run | Startup only |
| Maintenance effect | Suppresses console + email | Suppresses email only |

### Locking behaviour

Unlike one-shot scripts (which exit silently with code 0 when another instance is running), this daemon **dies with an error** if a lock cannot be acquired. This allows systemd to log the conflict and apply its restart policy correctly.

### Unit file generation

The unit file is generated dynamically at runtime, not stored statically. `readlink -f "$0"` resolves the real script path so `ExecStart` always points to the correct location, even when the script is called via a symlink. `WATCH_DIR` and `ALERT_EMAIL` are embedded as `Environment=` lines.

---

## Logging

### Directory structure

```
scripts/
├── file-change-monitor.sh
├── file-change-monitor.email.state
├── file-change-monitor.lock
├── file-change-monitor.maintenance
└── logs/
    ├── file-change-monitor-error.log
    ├── file-change-monitor-error.log.2026-06-01_120000
    ├── file-change-monitor-execution.log
    └── file-change-monitor-execution.log.2026-06-01_120000
```

### Execution log

Records every filesystem event:

```
2026-06-20 10:00:00 START [app-prod-01] watching /opt/app/data for: create modify delete
2026-06-20 10:00:01 EVENT CREATE /opt/app/data/report.csv
2026-06-20 10:00:02 EVENT MODIFY /opt/app/data/report.csv
2026-06-20 10:00:03 EVENT DELETE /opt/app/data/old-report.csv
2026-06-20 10:00:03 Email suppressed (maintenance mode active)
```

### Error log

Records only alert events and email actions:

```
2026-06-20 10:00:03 ALERT DELETE /opt/app/data/old-report.csv
2026-06-20 10:00:03 EMAIL sent to ops@example.com
```

### Log rotation

Rotation runs once at daemon startup. If a log file is older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. For rotation while the daemon is running without a restart, use `logrotate` with the `copytruncate` directive:

```
/opt/scripts/logs/file-change-monitor-*.log {
    daily
    rotate 14
    compress
    copytruncate
    missingok
    notifempty
}
```

---

## Use cases

### Watching a critical config directory

Alert on any deletion in a configuration directory:

```bash
WATCH_DIR="/etc/nginx/conf.d"
EVENTS=("create" "modify" "delete")
ALERT_EVENTS=("delete")
ALERT_EMAIL="ops@company.com infra@company.com"
```

### Watching an upload directory

Alert on every new file arriving:

```bash
WATCH_DIR="/var/upload/incoming"
EVENTS=("create" "moved_to")
ALERT_EVENTS=("create" "moved_to")
EMAIL_INTERVAL="60"   # up to one email per minute
```

### Watching a secrets or key store

Alert on any change to a sensitive directory:

```bash
WATCH_DIR="/etc/ssl/private"
EVENTS=("create" "modify" "delete" "moved_from" "moved_to")
ALERT_EVENTS=("create" "modify" "delete" "moved_from" "moved_to")
ALERT_EMAIL="security@company.com"
EMAIL_INTERVAL="0"  # alert on every event (no rate-limiting)
```

Wait — `EMAIL_INTERVAL="0"` would mean checking `(( now - last >= 0 ))` which is always true. This effectively disables rate-limiting. Use with caution in busy directories.

### Container sidecar

Watch a mounted volume for changes:

```bash
WATCH_DIR="/mnt/shared-volume"
HOSTNAME_LABEL="k8s-filewatch-prod"
ERROR_LOG=""
EXECUTION_LOG=""
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `WATCH_DIR` | `/path/to/directory` | Directory to monitor. |
| `EVENTS` | `("create" "modify" "delete")` | inotify events to watch. |
| `ALERT_EVENTS` | `("delete")` | Events that trigger an email alert. |
| `SERVICE_PATH` | `/etc/systemd/system/file-change-monitor.service` | Unit file destination for `--install-service`. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/file-change-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/file-change-monitor-error.log` | Alert events log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/file-change-monitor-execution.log` | All events log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/file-change-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration, watch and print events — but preview alerts instead of sending them. |
| `--print-unit` | Print the systemd unit file to stdout. |
| `--install-service` | Write the unit to `SERVICE_PATH` and reload systemd. |
| `--maintenance` | Toggle maintenance mode. Email is suppressed while active; console output continues. |
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