# mount-monitor.sh

Lightweight Bash script that checks whether one or more expected mountpoints are mounted and alerts when any of them are missing. Designed for Linux servers and containers where NFS shares, SAN volumes, or other network/block storage must be reliably available.

Reads directly from the kernel (`/proc/self/mounts`) with automatic fallback to standard commands, so it works on any Linux distribution and inside containers — without additional dependencies.

---

## Features

- **Kernel-first detection** — reads `/proc/self/mounts` (no external binary needed); falls back to `mountpoint(1)` then `mount(1)` if `/proc` is unavailable.
- **Multi-mount support** — configure any number of mountpoints in a single array.
- **Color-coded terminal output** — green for mounted, red for not mounted; automatically suppressed in cron, pipes, and container logs.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Recovery notifications** — sends a single email when all mounts come back after an alert (ALERT → OK transition).
- **Alert deduplication** — alerts fire once on the OK → ALERT transition and are suppressed on every subsequent run until mounts recover. Prevents repeated emails during a sustained outage.
- **Maintenance mode** — toggle alert suppression for planned downtime with `--maintenance`. State persists across runs.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images, no hard dependencies beyond Bash.
- **Dry-run mode** — check prerequisites and preview all actions (alerts, emails, logging decisions) without actually firing anything.
- **Self-contained configuration** — all settings live inside the script; cron entries and container commands stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies.

---

## Requirements

- **Bash 4.x+** (present on virtually all modern Linux systems and most container base images).
- **Linux kernel with `/proc` mounted** (standard on all distributions and container runtimes).
- **`mail` command** (optional; only needed for email alerts).
- **A configured MTA/relay** (optional; only needed for email delivery).
- **`find` command** (optional; only needed for log rotation. If missing, rotation is silently skipped).
- **`flock` command** (optional; only needed to prevent overlapping cron runs. If missing, locking is silently skipped).

No other dependencies. The script does not require `root`, though it needs read access to `/proc/self/mounts` and to the mountpoints being checked.

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/mount-monitor.sh \
     -o /opt/scripts/mount-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/mount-monitor.sh \
     -O /opt/scripts/mount-monitor.sh
```

### Manual copy

```bash
cp mount-monitor.sh /opt/scripts/mount-monitor.sh
```

### Make executable and verify

```bash
chmod +x /opt/scripts/mount-monitor.sh
/opt/scripts/mount-monitor.sh --version
/opt/scripts/mount-monitor.sh --help
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries and container commands stay clean.

### Mountpoints

```bash
MOUNTS=("/mnt/data" "/mnt/backup")
```

Add or remove paths as needed. Each path is checked independently.

```bash
# Single mount.
MOUNTS=("/mnt/nfs-share")

# Multiple mounts (NFS, SAN, local).
MOUNTS=("/mnt/data" "/mnt/backup" "/srv/nfs" "/mnt/san-vol01")
```

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/mount-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/mount-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com dev@example.com manager@example.com"
```

All listed addresses receive the same alert email.

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/mount-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/mount-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/mount-monitor-error.log` | Alerts and errors only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/mount-monitor-execution.log` | Every run (start, result, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

Logging is fully optional. If the log directory cannot be created or a file cannot be written, the script prints a warning and continues. This ensures the script never fails on read-only filesystems.

To disable logging entirely, set both to empty in the script:

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

Set this when running in containers, Kubernetes pods, or any environment where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

This makes alerts readable: `Mountpoints not mounted on app-prod-01: /mnt/data` instead of `Mountpoints not mounted on a1b2c3d4e5f6: /mnt/data`.

The resolution order when `HOSTNAME_LABEL` is empty: `$HOSTNAME` environment variable, then `hostname` command, then `"unknown"`.

---

## Usage

```
Usage: mount-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./mount-monitor.sh
```

```
/mnt/data                      mounted
/mnt/backup                    NOT mounted
ALERT: Mountpoints not mounted on app-prod-01: /mnt/backup
```

### Dry-run

Prints a full prerequisites report (tools available, active configuration, current state) and then previews every action the script would take — without writing any files, sending any emails, or updating any state.

```bash
./mount-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/self/mounts            OK
  mountpoint                   OK (fallback)
  mount                        OK (fallback)
  mail                         MISSING (email will not work)
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     app-prod-01
  Mounts:                      /mnt/data /mnt/backup
  E-Mail:                      DISABLED
  Error log:                   /opt/scripts/logs/mount-monitor-error.log
  Execution log:               /opt/scripts/logs/mount-monitor-execution.log
  Log retention:               14 days

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

/mnt/data                      mounted
/mnt/backup                    NOT mounted
[dry-run] would raise alert: /mnt/backup
[dry-run] would email: ops@example.com (last sent: 1200s ago)
```

### Maintenance mode

Toggle alert suppression for planned downtime. The state persists across runs until toggled off.

```bash
# Enable maintenance mode (alerts suppressed).
./mount-monitor.sh --maintenance
# Maintenance mode enabled

# Disable maintenance mode (alerts resume).
./mount-monitor.sh --maintenance
# Maintenance mode disabled
```

While maintenance mode is active, the script still checks and logs mountpoints — only alerting (console and email) is suppressed.

---

## How it works

### Mount detection (source priority)

1. **`/proc/self/mounts`** (preferred) — the kernel's own list of active mounts. Read directly by Bash, no binary needed. Available on every Linux system and inside every standard container.

2. **`mountpoint -q`** (fallback 1) — from `util-linux`. Used only if `/proc/self/mounts` is not readable.

3. **`mount` command`** (fallback 2) — output parsed with `awk`. Used only if neither of the above is available.

If no source is available, the script exits with a clear error. In practice, `/proc/self/mounts` is always present.

### Alert flow

Alerts fire once per state transition, not once per cron run. This prevents alert storms during sustained outages.

```
Mountpoint check
    │
    ├── All mounted
    │       │
    │       ├── Status was ALERT ──── Send recovery email ── Set status OK
    │       └── Status was OK    ──── Log "all mounted" ──── Exit
    │
    └── Some not mounted
            │
            ├── Status was OK    ──── Set status ALERT ── Fire alert (console + email)
            └── Status was ALERT ──── Log "already in ALERT state" ── Exit (no repeat)
                                       (email rate-limit still enforced if alert fires)
```

### Status tracking

The script stores the current alert state (`OK` or `ALERT`) in `STATUS_FILE`. This is what prevents repeated notifications on every cron cycle:

- **OK → ALERT**: alert fires (console + email). `STATUS_FILE` is written with `ALERT`.
- **ALERT → ALERT**: alert is suppressed. `STATUS_FILE` unchanged.
- **ALERT → OK**: recovery email sent. `STATUS_FILE` is written with `OK`.
- **OK → OK**: nothing extra. `STATUS_FILE` unchanged.

If `STATUS_FILE` is missing or corrupted, the script treats the state as `OK` and behaves as if starting fresh.

### Email rate-limiting

A Unix timestamp is stored in `STATE_FILE` after each email. On the next alert, the script checks whether `EMAIL_INTERVAL` seconds have passed. If not, the email is skipped. Console alerts are never rate-limited.

If the state file is missing, empty, or corrupt, the script treats it as "never sent" and allows the email.

---

## Logging

### Directory structure

```
scripts/
├── mount-monitor.sh
└── logs/
    ├── mount-monitor-error.log                         ← active
    ├── mount-monitor-error.log.2026-06-01_120000       ← rotated archive
    ├── mount-monitor-execution.log                     ← active
    └── mount-monitor-execution.log.2026-06-01_120000   ← rotated archive
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] checking 3 mount(s): /mnt/data /mnt/backup /srv/nfs
2026-06-20 10:00:01 RESULT all mounted
2026-06-20 10:00:01 END
```

The `[hostname]` tag identifies the source when logs from multiple hosts are aggregated.

### Error log

```
2026-06-20 11:00:01 ALERT /mnt/backup
2026-06-20 11:00:01 EMAIL sent to ops@example.com dev@example.com
2026-06-20 12:15:43 RECOVERY EMAIL sent to ops@example.com dev@example.com
```

### Log rotation

At every run, the script checks each log file:

1. If older than `LOG_RETENTION_DAYS`, rename with a timestamp suffix and start fresh.
2. Delete archived copies older than `LOG_RETENTION_DAYS`.

Self-contained — no dependency on `logrotate`. If `find` is not available (minimal containers), rotation is silently skipped and logs continue to append.

| `LOG_RETENTION_DAYS` | Behavior |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

---

### State files

The script maintains three state files next to itself (all paths are configurable):

| File | Variable | Purpose |
|---|---|---|
| `mount-monitor.status` | `STATUS_FILE` | Current alert state: `OK` or `ALERT`. Controls alert deduplication and recovery detection. |
| `mount-monitor.email.state` | `STATE_FILE` | Unix timestamp of the last sent email. Used for rate-limiting. |
| `mount-monitor.maintenance` | `MAINTENANCE_FILE` | Presence of this file activates maintenance mode. Created/removed by `--maintenance`. |
| `mount-monitor.lock` | `LOCK_FILE` | `flock(1)` lock file. Prevents overlapping cron runs. |

All state files are best-effort: if they cannot be created or read (e.g. read-only filesystem), the script degrades gracefully and continues.

---

### Container usage

The script is designed to work inside Docker, Podman, LXC/Incus, and Kubernetes containers without modification.

### What works out of the box

- **`/proc/self/mounts`** is available in all standard Linux containers. The kernel provides it regardless of the container runtime.
- **Colors are auto-disabled** when stdout is not a terminal (standard in container log drivers).
- **Logging degrades gracefully** on read-only filesystems — a warning is printed and the script continues.
- **No hard dependencies** beyond Bash. The script does not require `find`, `mountpoint`, `mount`, `mail`, or any other binary to run its core check.

### Dockerfile example

```dockerfile
FROM alpine:latest
RUN apk add --no-cache bash
COPY mount-monitor.sh /opt/scripts/mount-monitor.sh
RUN chmod +x /opt/scripts/mount-monitor.sh
CMD ["/opt/scripts/mount-monitor.sh"]
```

### Docker Compose with a volume check

```yaml
services:
  mount-check:
    image: alpine:latest
    volumes:
      - ./mount-monitor.sh:/opt/scripts/mount-monitor.sh:ro
      - app-data:/mnt/data:ro
    command: ["bash", "/opt/scripts/mount-monitor.sh"]
```

### Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mount-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: mount-monitor
            image: alpine:latest
            command: ["bash", "/opt/scripts/mount-monitor.sh"]
            volumeMounts:
            - name: script
              mountPath: /opt/scripts
              readOnly: true
            - name: data
              mountPath: /mnt/data
              readOnly: true
          volumes:
          - name: script
            configMap:
              name: mount-monitor-script
          - name: data
            persistentVolumeClaim:
              claimName: app-data
          restartPolicy: OnFailure
```

### Container-specific configuration

Set `HOSTNAME_LABEL` in the script to give the container a human-readable name in alerts and logs:

```bash
HOSTNAME_LABEL="app-prod-01"
```

Without this, alerts show the container ID (e.g., `a1b2c3d4e5f6`), which is not useful.

For containers with read-only root filesystems, either disable logging:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

Or point logs and state to a writable volume:

```bash
LOG_DIR="/mnt/logs"
STATE_FILE="/mnt/logs/mount-monitor.email.state"
```

### Persistence across container restarts

`STATE_FILE` (email rate-limit timestamp) and `STATUS_FILE` (alert state) both default to the script directory, which may be lost on container restart. To preserve alert deduplication and rate-limiting across restarts, point both to a persistent volume:

```bash
STATE_FILE="/mnt/persistent/mount-monitor.email.state"
STATUS_FILE="/mnt/persistent/mount-monitor.status"
```

---

## Integration

### Container usage (Kubernetes / Docker)

When running inside a container, set `HOSTNAME_LABEL` to a meaningful name
since the container hostname is typically an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

On read-only container filesystems, disable file-based state by pointing
state files to a writable volume or disabling them:

```bash
STATUS_FILE="/tmp/mount-monitor.status"
STATE_FILE="/tmp/mount-monitor.email.state"
LOG_DIR="/tmp/logs"
```

Or disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mount-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: mount-monitor
            image: alpine/bash
            command: ["/scripts/mount-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

Edit the script to configure all settings, then add a clean cron entry:

```cron
*/5 * * * * /opt/scripts/mount-monitor.sh >/dev/null 2>&1
```

All configuration lives in the script — the cron line needs nothing else.

To capture output in syslog:

```cron
*/5 * * * * /opt/scripts/mount-monitor.sh 2>&1 | logger -t mount-monitor
```

### Checkmk (local check)

Place the script in the Checkmk local checks directory:

```bash
cp mount-monitor.sh /usr/lib/check_mk_agent/local/mount-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output. The function is designed as a seam for this purpose.

### Grafana / Prometheus (textfile collector)

Add a Prometheus metric inside `alert()`:

```bash
echo "mount_monitor_down{host=\"${HOST_ID}\"} ${#down[@]}" \
    > /var/lib/node_exporter/mount-monitor.prom
```

### systemd timer

```ini
# /etc/systemd/system/mount-monitor.service
[Unit]
Description=Mount monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/mount-monitor.sh
```

```ini
# /etc/systemd/system/mount-monitor.timer
[Unit]
Description=Run mount monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now mount-monitor.timer
```

---

## Use cases

### NFS shares on application servers

```bash
MOUNTS=("/mnt/app-data" "/mnt/shared-config" "/mnt/logs-nfs")
ALERT_EMAIL="ops@company.com infra@company.com"
EMAIL_INTERVAL="1800"
```

### Backup volume pre-check

```bash
if ! /opt/scripts/mount-monitor.sh >/dev/null 2>&1; then
    echo "Backup aborted: required mounts missing" >&2
    exit 1
fi
```

### Multi-environment infrastructure

Maintain separate copies per environment, each with its own configuration:

```
/opt/scripts/
├── mount-monitor-prod.sh
├── mount-monitor-staging.sh
└── mount-monitor-dev.sh
```

```cron
*/5 * * * * /opt/scripts/mount-monitor-prod.sh    >/dev/null 2>&1
*/5 * * * * /opt/scripts/mount-monitor-staging.sh >/dev/null 2>&1
```

### Containerized applications

```bash
MOUNTS=("/mnt/data" "/mnt/config")
HOSTNAME_LABEL="api-prod-west-01"
ERROR_LOG=""
EXECUTION_LOG=""
```

---

## Configuration reference

All variables are set inside the script.

| Variable | Default | Description |
|---|---|---|
| `MOUNTS` | `("/mnt/data" "/mnt/backup")` | Array of mountpoints to check. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between emails. |
| `STATE_FILE` | `<script_dir>/mount-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/mount-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/mount-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts/logs. |
| `STATUS_FILE` | `<script_dir>/mount-monitor.status` | Alert state file (`OK` / `ALERT`). |
| `MAINTENANCE_FILE` | `<script_dir>/mount-monitor.maintenance` | Maintenance mode marker (auto-managed). |

---

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Check prerequisites, show configuration and state, preview actions without performing them. |
| `--maintenance` | Toggle maintenance mode on/off. Alerts are suppressed while active. |
| `--version` | Print version and exit. |
| `--help` | Print usage information and exit. |

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