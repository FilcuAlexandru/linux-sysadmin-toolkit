# ssh-config-audit.sh

Audit sshd configuration for insecure settings.

---

## Features

- Uses `sshd -T` for the true effective configuration when available.
- Falls back to parsing `sshd_config` with comments stripped.
- Flags root login, password auth, empty passwords, protocol 1, X11 forwarding.
- Status-aware alerting with recovery email and rate-limiting.
- Maintenance mode, locking, structured logging with rotation.
- **Status tracking** — alerts once when a problem appears, stays silent while it persists, and sends a recovery email when it clears.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with a graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the status of every dependency, the full configuration, and the current runtime state before previewing actions.
- **Monitoring integration** — the `alert()` function is a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels and graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux** with the `/proc` (and, where noted, `/sys`) filesystem.

Dependencies (the script warns and continues without the optional ones):

- `sshd` (openssh-server) — preferred for effective config
- `awk` — required
- read access to `sshd_config` — fallback
- `mail` / `flock` / `find` — optional

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-sysadmin-toolkit.git
cd linux-sysadmin-toolkit/bash/ssh-config-audit

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-sysadmin-toolkit/main/bash/ssh-config-audit/ssh-config-audit.sh \
     -o /opt/scripts/ssh-config-audit.sh
```

### Manual copy

```bash
cp ssh-config-audit.sh /opt/scripts/ssh-config-audit.sh
chmod +x /opt/scripts/ssh-config-audit.sh
```

### Verify

```bash
/opt/scripts/ssh-config-audit.sh --version
/opt/scripts/ssh-config-audit.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives
below a clearly marked separator line (`no changes needed past this line`) — you never need to edit
anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script
once; cron entries stay clean.

### Script settings

```bash
SSHD_CONFIG="/etc/ssh/sshd_config"
```

| Variable | Default | Description |
|---|---|---|
| `SSHD_CONFIG` | `/etc/ssh/sshd_config` | Fallback config path when `sshd -T` is unavailable. |

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/ssh-config-audit.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/ssh-config-audit.email.state` | Stores the timestamp of the last sent email. |

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/ssh-config-audit-error.log"
EXECUTION_LOG="${LOG_DIR}/ssh-config-audit-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/ssh-config-audit-error.log` | Alerts, emails, and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/ssh-config-audit-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable -> `hostname` command -> `"unknown"`.

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/ssh-config-audit.maintenance"
LOCK_FILE="${SCRIPT_DIR}/ssh-config-audit.lock"
STATUS_FILE="${SCRIPT_DIR}/ssh-config-audit.status"
```

These files are managed automatically. Override paths only when the script directory is read-only.

---

## Usage

```
Usage: ssh-config-audit.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./ssh-config-audit.sh
```

### Dry-run

```bash
./ssh-config-audit.sh --dry-run
```

```
Prerequisites:
  sshd                         OK
  awk                          OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Privileges:                  root
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/ssh-config-audit-error.log
  Execution log:               /opt/scripts/logs/ssh-config-audit-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK
```

The dry-run lists every dependency (OK / MISSING), the active configuration and privilege level, and
the current runtime state, then previews the alert that *would* fire — without sending anything or
changing state.

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./ssh-config-audit.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./ssh-config-audit.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

The script obtains the effective SSH configuration via `sshd -T` (falling back to the config file) and checks for a set of well-known insecure directives, alerting if any are present with hardening recommendations.

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
                 condition detected (first time)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
                 condition persists (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
                 condition clears
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

One alert email when the problem starts, one recovery email when it ends.

### Instance locking

Uses `flock(1)` to prevent overlapping runs. If another instance holds the lock, the new one exits
silently with code 0 so cron does not report an error. Skipped gracefully when `flock` is unavailable
or the lock file cannot be created (read-only filesystem).

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each alert email. On the next OK→ALERT transition, the
script checks whether `EMAIL_INTERVAL` seconds have passed. This is a safety net; the status tracking
above is the primary deduplication mechanism. Recovery emails are never rate-limited.

---

## Logging

### Directory structure

```
scripts/
├── ssh-config-audit.sh
├── ssh-config-audit.status
├── ssh-config-audit.email.state
├── ssh-config-audit.lock
├── ssh-config-audit.maintenance
└── logs/
    ├── ssh-config-audit-error.log
    ├── ssh-config-audit-error.log.2026-06-01_120000
    ├── ssh-config-audit-execution.log
    └── ssh-config-audit-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 08:00:01 START [app-prod-01]
2026-06-20 08:00:01 RESULT ... (ok)
2026-06-20 08:00:01 END
```

### Error log

```
2026-06-20 08:00:01 ALERT ...
2026-06-20 08:00:01 EMAIL sent to ops@example.com
2026-06-20 09:15:00 RECOVERY EMAIL sent to ops@example.com
```

### Log rotation

At every run, each log older than `LOG_RETENTION_DAYS` is renamed with a timestamp suffix and a fresh
log is started; archived copies past the window are deleted. Self-contained — no dependency on
`logrotate`. If `find` is unavailable, rotation is silently skipped.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

## Integration

### Container usage (Kubernetes / Docker)

Set `HOSTNAME_LABEL` to a meaningful name, and on read-only filesystems point state files at a
writable volume:

```bash
HOSTNAME_LABEL="app-prod-01"
STATUS_FILE="/tmp/ssh-config-audit.status"
STATE_FILE="/tmp/ssh-config-audit.email.state"
LOG_DIR="/tmp/logs"
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ssh-config-audit
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: ssh-config-audit
            image: alpine/bash
            command: ["/scripts/ssh-config-audit.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```

### Cron

```cron
*/5 * * * * /opt/scripts/ssh-config-audit.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

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

```bash
sudo systemctl enable --now ssh-config-audit.timer
```

### Checkmk (local check)

```bash
cp ssh-config-audit.sh /usr/lib/check_mk_agent/local/ssh-config-audit.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Emit a Prometheus metric from inside `alert()`:

```bash
echo "ssh_config_audit_alert{host=\"${HOST_ID}\"} 1" \
    > /var/lib/node_exporter/ssh-config-audit.prom
```

---

## Use cases

### Scheduled monitoring with email alerts

```bash
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="3600"
HOSTNAME_LABEL="app-prod-01"
```

Run every few minutes from cron; the on-call team gets one email when the problem starts and one when
it recovers.

### Container / sidecar check

```bash
HOSTNAME_LABEL="k8s-worker-prod-03"
ERROR_LOG=""
EXECUTION_LOG=""
```

Logging disabled for container environments where stdout/stderr is captured by the runtime.

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `SSHD_CONFIG` | `/etc/ssh/sshd_config` | Fallback config path when `sshd -T` is unavailable. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/ssh-config-audit.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory (auto-created). |
| `ERROR_LOG` | `<LOG_DIR>/ssh-config-audit-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/ssh-config-audit-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs; `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/ssh-config-audit.maintenance` | Maintenance marker. |
| `LOCK_FILE` | `<script_dir>/ssh-config-audit.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/ssh-config-audit.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview the action — without performing anything. |
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
