# user-manager.py

Manages local users with JSON output and append-only audit trail. Outputs structured JSON to stdout on every run. Part of the Python SysAdmin Toolkit.

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
cp user-manager.py /opt/scripts/user-manager.py
chmod +x /opt/scripts/user-manager.py
python3 /opt/scripts/user-manager.py --version
python3 /opt/scripts/user-manager.py --dry-run
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
./user-manager.py add     <username> [--shell SHELL] [--groups g1,g2] [--comment TEXT] [--ssh-key KEY] [--dry-run]
./user-manager.py remove  <username> [--remove-home] [--dry-run]
./user-manager.py lock    <username> [--dry-run]
./user-manager.py unlock  <username> [--dry-run]
./user-manager.py list    [--min-uid N]
./user-manager.py set-shell <username> <shell> [--dry-run]
./user-manager.py add-key   <username> <public_key> [--dry-run]
./user-manager.py --version
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
| `user-manager-execution.log` | Every run: start, result, end. |
| `user-manager-error.log` | Alerts, recovery emails, and errors only. |

Both are auto-rotated when older than `LOG_RETENTION_DAYS` days.

---

## Integration examples

### Cron (every 5 minutes)

```cron
*/5 * * * * /opt/scripts/user-manager.py >> /var/log/user-manager.json 2>/dev/null
```

### Pipe to jq

```bash
python3 user-manager.py | jq '.data'
python3 user-manager.py | jq '.alerts[]'
python3 user-manager.py | jq '.status'
```

### Checkmk local check

```bash
cp user-manager.py /usr/lib/check_mk_agent/local/user-manager.py
```

### Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: user-manager
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: user-manager
            image: python:3.11-slim
            command: ["python3", "/scripts/user-manager.py"]
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
| `DEFAULT_SHELL` | See inline comment in script. |
| `DEFAULT_GROUPS` | See inline comment in script. |
| `CREATE_HOME` | See inline comment in script. |
| `SKEL_DIR` | See inline comment in script. |
| `AUDIT_LOG` | See inline comment in script. |

---

## CLI reference

| Subcommand | Description |
|---|---|
| `add <username>` | Create a new local user. |
| `remove <username>` | Remove a local user. |
| `lock <username>` | Lock an account (usermod -L). |
| `unlock <username>` | Unlock an account (usermod -U). |
| `list` | List regular users (uid >= min-uid). |
| `set-shell <username> <shell>` | Change login shell. |
| `add-key <username> <key>` | Append SSH public key to authorized_keys. |
| `--version` | Print version and exit. |

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
