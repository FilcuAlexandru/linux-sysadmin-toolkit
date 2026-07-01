# tls-cert-scanner.py

Scan the filesystem for TLS certificates nearing expiry.

---

## Purpose

Walks `SCAN_DIRS` for certificate files, reads each expiry date with `openssl x509`, and alerts on certificates already expired or expiring within `EXPIRY_DAYS`.

---

## Features

- **Recursively discovers .crt/.pem/.cer files.**
- **Parses real expiry dates via openssl.**
- **Separate handling of expired vs. soon-to-expire certs.**
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

- `openssl`
- `mail` command — only needed for email alerts.

---

## Installation

```bash
cp tls-cert-scanner.py /opt/scripts/tls-cert-scanner.py
chmod +x /opt/scripts/tls-cert-scanner.py
python3 /opt/scripts/tls-cert-scanner.py --version
python3 /opt/scripts/tls-cert-scanner.py --dry-run
```

---

## Usage

```bash
python3 tls-cert-scanner.py              # run; prints a JSON result on stdout
python3 tls-cert-scanner.py --dry-run    # print configuration and state, do nothing
python3 tls-cert-scanner.py --maintenance # toggle maintenance mode (suppresses alerts)
python3 tls-cert-scanner.py --version    # print version and exit
```

### Output

On a normal run the script prints a JSON document:

```json
{
  "timestamp": "2026-06-30T10:00:00Z",
  "host": "app-prod-01",
  "script": "tls-cert-scanner",
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
| `SCAN_DIRS` | `see script` | Directories to scan for certificates. |
| `EXPIRY_DAYS` | `30` | Alert when a certificate expires within this many days. |

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
*/5 * * * * /usr/bin/python3 /opt/scripts/tls-cert-scanner.py >/dev/null 2>&1
```

### systemd timer

```ini
# /etc/systemd/system/tls-cert-scanner.service
[Unit]
Description=tls-cert-scanner check
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/scripts/tls-cert-scanner.py
```

```ini
# /etc/systemd/system/tls-cert-scanner.timer
[Unit]
Description=Run tls-cert-scanner every 5 minutes
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
  when the condition clears (state in `tls-cert-scanner.status`).
- *Safe by default:* the script is read-only with respect to system state — it inspects and reports.
- *Graceful degradation:* missing optional tools downgrade features rather than failing the run; a
  genuinely unexpected error is reported as `status: ERROR` with exit code `2`.

---

## Author

**Filcu Alexandru**

## License

MIT
