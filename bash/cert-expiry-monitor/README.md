# cert-expiry-monitor.sh

Lightweight Bash script that checks one or more certificates and alerts when any of them are close to expiring. Supports PEM/DER files, remote TLS endpoints, and Java keystores (JKS/PKCS12 via `keytool`). Multiple certificates of different types can be monitored in a single run.

Designed for environments where certificate paths, tool locations, and keystore formats vary — including enterprise Linux servers running WebLogic, Tomcat, or nginx, and containerized workloads.

---

## Features

- **Multi-certificate support** — monitor any number of certificates in a single array, each with its own type and path.
- **Three certificate types** — PEM/DER files, remote TLS hosts (via `openssl s_client`), and Java keystores (JKS/PKCS12 via `keytool`).
- **Explicit binary paths** — set `KEYTOOL_BIN` and `OPENSSL_BIN` when tools are not in `$PATH` (common on enterprise Linux with non-standard JDK locations).
- **Keystore alias scanning** — for JKS/PKCS12 stores, reads all aliases and alerts on the one that expires soonest.
- **Graceful skip on missing entries** — empty entries, missing files, unavailable tools, and unknown types are warned and skipped; the rest of the list still runs.
- **Aggregated alerts** — all expiring certificates are collected and reported in a single alert message and a single email per run.
- **Configurable threshold** — alert window is set in days (`THRESHOLD_DAYS`, default 30).
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows the resolved path of every tool, the full certificate list, and the current runtime state before previewing actions.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems and minimal images.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — no package manager, no distro-specific paths, no compiled dependencies beyond Bash.

---

## Requirements

- **Bash 4.x+**
- **Linux kernel with `/proc` mounted** (standard on all distributions and containers)

Optional (the script warns and skips the relevant entries if missing):

- **`openssl`** — required for `file` and `host` certificate checks.
- **`keytool`** (JDK/JRE) — required for `keytool` entries (JKS/PKCS12 keystores).
- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for instance locking (`util-linux`).
- **`find`** — for log rotation (`findutils`).

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/cert-expiry-monitor.sh \
     -o /opt/scripts/cert-expiry-monitor.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/cert-expiry-monitor.sh \
     -O /opt/scripts/cert-expiry-monitor.sh
```

### Manual copy

```bash
cp cert-expiry-monitor.sh /opt/scripts/cert-expiry-monitor.sh
chmod +x /opt/scripts/cert-expiry-monitor.sh
```

### Verify

```bash
/opt/scripts/cert-expiry-monitor.sh --version
/opt/scripts/cert-expiry-monitor.sh --dry-run
```

`--dry-run` is the recommended first step on any new host — it shows exactly which tools were found, at what paths, and what the script would do before making any changes.

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

**Do not pass configuration variables inline in cron or on the command line.** Edit them in the script once; cron entries stay clean.

### Certificates

```bash
CERTS=(
    "host|example.com:443|"
)
```

Each entry is a pipe-separated descriptor with three fields:

```
type|target|opts
```

| Field | Description |
|---|---|
| `type` | Certificate source type: `file`, `host`, or `keytool`. |
| `target` | Path to a file, `host:port` for TLS, or path to a keystore. |
| `opts` | Type-specific option (password for `keytool`; leave empty for others). |

#### Type: `file` — PEM/DER certificate file

```bash
"file|/etc/ssl/certs/nginx.crt|"
"file|/opt/app/certs/server.pem|"
```

Reads the certificate directly using `openssl x509`. Supports PEM and DER formats. The file must be readable by the user running the script.

#### Type: `host` — Remote TLS endpoint

```bash
"host|example.com:443|"
"host|internal-api.company.com:8443|"
"host|ldap.company.com:636|"
"host|smtp.company.com:587|"
```

Connects to the host using `openssl s_client` with SNI and reads the served certificate. Port defaults to `443` if not specified.

#### Type: `keytool` — Java keystore (JKS or PKCS12)

```bash
"keytool|/opt/weblogic/user_projects/domains/mydomain/identity.jks|changeit"
"keytool|/opt/weblogic/user_projects/domains/mydomain/trust.jks|changeit"
"keytool|/opt/app/keystore.p12|mypassword"
```

Uses `keytool -list -v` to read all aliases in the keystore and alerts on the alias that expires soonest. The third field is the keystore password (`storepass`).

#### Mixed example

```bash
CERTS=(
    "file|/etc/nginx/ssl/company.crt|"
    "host|api.company.com:443|"
    "host|internal-api.company.com:8443|"
    "keytool|/opt/weblogic/identity.jks|changeit"
    "keytool|/opt/weblogic/trust.jks|changeit"
    "keytool|/opt/app/keystore.p12|secretpassword"
)
```

#### Skipping entries temporarily

Leave an entry empty to skip it without removing it:

```bash
CERTS=(
    "file|/etc/nginx/ssl/company.crt|"
    ""                                        # identity.jks: rotating this week
    "keytool|/opt/weblogic/trust.jks|changeit"
)
```

Empty entries, entries with missing fields, files that do not exist, unavailable tools, and unknown types are all warned and skipped. The remaining entries are always checked.

### Binary paths

```bash
KEYTOOL_BIN=""
OPENSSL_BIN=""
```

| Variable | Default | Description |
|---|---|---|
| `KEYTOOL_BIN` | `""` *(auto-detect from `$PATH`)* | Explicit path to the `keytool` binary. |
| `OPENSSL_BIN` | `""` *(auto-detect from `$PATH`)* | Explicit path to the `openssl` binary. |

Set these when the tools are installed in non-standard locations, which is common on enterprise Linux servers where the JDK is installed by the vendor rather than the package manager.

#### When to set `KEYTOOL_BIN`

`keytool` is part of the JDK. On many enterprise Linux installations it is not symlinked into `/usr/bin`, so `command -v keytool` returns nothing even though the JDK is installed. Common locations:

```bash
# Oracle JDK on RHEL/CentOS
KEYTOOL_BIN="/usr/java/jdk-21/bin/keytool"

# OpenJDK from RPM on SLES / RHEL
KEYTOOL_BIN="/usr/lib64/jvm/java-21-openjdk/bin/keytool"

# WebLogic bundled JDK
KEYTOOL_BIN="/opt/oracle/middleware/jdk/bin/keytool"

# Custom JDK installation
KEYTOOL_BIN="/opt/jdk/bin/keytool"
```

#### When to set `OPENSSL_BIN`

Usually `openssl` is in `$PATH` on standard Linux distributions. Set this when using a custom-compiled OpenSSL, a version pinned for FIPS compliance, or a container base image where OpenSSL is not in the default search path:

```bash
OPENSSL_BIN="/usr/local/openssl-3/bin/openssl"
OPENSSL_BIN="/opt/fips-openssl/bin/openssl"
```

#### Fallback behaviour

If `KEYTOOL_BIN` or `OPENSSL_BIN` is set but the file is not executable (wrong path, typo), the script prints a warning and falls back to `$PATH` lookup:

```
Warning: keytool not executable at '/opt/jdk/keytool'; falling back to PATH
```

If the tool cannot be found by either method, the relevant entries are skipped with a warning and the rest of the list continues.

#### Verifying resolved paths

`--dry-run` always shows the exact path that will be used:

```
Prerequisites:
  openssl                      OK (/usr/bin/openssl)
  keytool                      OK (/usr/java/jdk-21/bin/keytool)
```

This confirms which binary is active before the script runs in production or cron.

### Alert threshold

```bash
THRESHOLD_DAYS=30
```

Alert fires when a certificate expires within this many days. Set to `0` to alert only on already-expired certificates.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/cert-expiry-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/cert-expiry-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com security@example.com manager@example.com"
```

All listed addresses receive the same alert email in a single message.

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/cert-expiry-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/cert-expiry-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/cert-expiry-monitor-error.log` | Alerts and emails only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/cert-expiry-monitor-execution.log` | Every run (start, result per cert, end). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

To disable logging entirely:

```bash
ERROR_LOG=""
EXECUTION_LOG=""
```

### Host identification

```bash
HOSTNAME_LABEL=""
```

Set a custom label when running in containers where the hostname is an auto-generated ID:

```bash
HOSTNAME_LABEL="app-prod-01"
```

Resolution order when empty: `$HOSTNAME` variable → `hostname` command → `"unknown"`.

### Maintenance, locking, and state files

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/cert-expiry-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/cert-expiry-monitor.lock"
```

These are managed automatically by the script. Override the paths only when the script directory is read-only (e.g., mounted as a ConfigMap in Kubernetes).

---

## Usage

```
Usage: cert-expiry-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./cert-expiry-monitor.sh
```

```
file:/etc/nginx/ssl/company.crt            expires in 142 days
host:api.example.com:443                   expires in 8 days
host:internal-api.company.com:8443         expires in 65 days
keytool:/opt/weblogic/identity.jks         expires in 12 days
keytool:/opt/weblogic/trust.jks            expires in 142 days
ALERT: Certificate expiring soon on app-prod-01: host:api.example.com:443 (8 days), keytool:/opt/weblogic/identity.jks (12 days)
```

### Dry-run

```bash
./cert-expiry-monitor.sh --dry-run
```

```
Prerequisites:
  openssl                      OK (/usr/bin/openssl)
  keytool                      OK (/usr/java/jdk-21/bin/keytool)
  mail                         OK (/usr/bin/mail)
  flock                        OK (/usr/bin/flock)
  find                         OK (/usr/bin/find)

Configuration:
  Host ID:                     app-prod-01
  Threshold:                   30 days
  E-Mail:                      ops@example.com security@example.com
  E-Mail interval:             3600s
  Error log:                   /opt/scripts/logs/cert-expiry-monitor-error.log
  Execution log:               /opt/scripts/logs/cert-expiry-monitor-execution.log
  Log retention:               14 days

Certificates:
  [1] type=file       target=/etc/nginx/ssl/company.crt
  [2] type=host       target=api.example.com:443
  [3] (empty, will be skipped)
  [4] type=keytool    target=/opt/weblogic/identity.jks

State:
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

file:/etc/nginx/ssl/company.crt            expires in 142 days
host:api.example.com:443                   expires in 8 days
[dry-run] would raise alert: host:api.example.com:443 (8 days)
[dry-run] would email: ops@example.com security@example.com (last sent: never)
```

### Maintenance mode

```bash
# Enable (suppresses all alerts).
./cert-expiry-monitor.sh --maintenance
# Output: Maintenance mode enabled

# Disable (alerts resume on next run).
./cert-expiry-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Binary resolution

Before reading any certificate, the script resolves which binary to use via `resolve_bin()`:

1. If `KEYTOOL_BIN` / `OPENSSL_BIN` is set and the file is executable → use it directly.
2. If set but not executable → print a warning and fall back to `$PATH`.
3. If not set → look up in `$PATH`.
4. If not found by either method → warn and skip the entry that needs it.

The resolved path is shown in `--dry-run` output so you can verify before running in production.

### Certificate reading

Each `CERTS` entry is parsed and read independently:

**`file`** — runs `openssl x509 -enddate -noout -in <path>` and parses the `NotAfter` date.

**`host`** — connects with `openssl s_client -connect <host>:<port> -servername <host>`, pipes the output into `openssl x509 -enddate -noout`, and parses the `NotAfter` date. SNI is always sent.

**`keytool`** — runs `keytool -list -v -keystore <path> -storepass <password>` and scans all `until:` lines. The earliest expiry date across all aliases in the store is used for the threshold check.

### Skip conditions

An entry is skipped (with a warning on stderr and a `SKIP` line in the execution log) when:

| Condition | Warning message |
|---|---|
| Entry is empty or whitespace | *(silent)* |
| `type` or `target` field is missing | `incomplete entry '...' — skipping` |
| File or keystore path does not exist | `file not found: ...` / `keystore not found: ...` |
| Required tool not found | `openssl not found` / `keytool not found (set KEYTOOL_BIN or add to PATH)` |
| Certificate date cannot be parsed | `could not parse end date '...'` |
| No expiry dates in keystore | `could not read any expiry date from keystore: ...` |
| Unknown type | `unknown certificate type '...' — skipping entry` |

Skipped entries never prevent other entries from being checked.

### Alert flow

```
For each CERTS entry:
    │
    ├── Empty / invalid ──────────── warn + skip
    ├── Tool missing ──────────────── warn + skip
    ├── File / keystore not found ─── warn + skip
    │
    └── Read OK
            ├── days >= THRESHOLD ── green output, log RESULT ok
            └── days <  THRESHOLD ── red output,   log RESULT expiring
                                      add to expiring[]

After all entries:
    │
    ├── expiring[] empty ──── done
    └── expiring[] not empty
            │
            ├── Console ALERT (always)
            └── Email?
                 ├── ALERT_EMAIL empty ──── skip
                 ├── mail not found ─────── warn, skip
                 ├── Rate-limited ──────── skip (notice on stderr)
                 └── Interval passed ───── send to all recipients
                                            └── update STATE_FILE
```

All expiring certificates are collected first, then a **single alert** with all of them is raised. One email per check run, regardless of how many certificates are expiring simultaneously.

---

## Logging

### Directory structure

```
scripts/
├── cert-expiry-monitor.sh
├── cert-expiry-monitor.email.state
├── cert-expiry-monitor.lock
├── cert-expiry-monitor.maintenance
└── logs/
    ├── cert-expiry-monitor-error.log
    ├── cert-expiry-monitor-error.log.2026-06-01_120000
    ├── cert-expiry-monitor-execution.log
    └── cert-expiry-monitor-execution.log.2026-06-01_120000
```

### Execution log

```
2026-06-20 10:00:01 START [app-prod-01] checking 5 certificate(s)
2026-06-20 10:00:01 RESULT ok: file:/etc/nginx/ssl/company.crt expires in 142 days
2026-06-20 10:00:02 RESULT expiring: host:api.example.com:443 in 8 days
2026-06-20 10:00:02 RESULT ok: host:internal-api.company.com:8443 expires in 65 days
2026-06-20 10:00:02 SKIP unreadable: file:/etc/ssl/missing.pem
2026-06-20 10:00:03 RESULT expiring: keytool:/opt/weblogic/identity.jks in 12 days
2026-06-20 10:00:03 END
```

### Error log

```
2026-06-20 10:00:02 ALERT host:api.example.com:443 (8 days), keytool:/opt/weblogic/identity.jks (12 days)
2026-06-20 10:00:02 EMAIL sent to ops@example.com security@example.com
```

### Log rotation

At every run, the script checks each log file. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Archived copies older than the retention window are deleted.

Self-contained — no dependency on `logrotate`. If `find` is unavailable, rotation is silently skipped.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |

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
STATUS_FILE="/tmp/cert-expiry-monitor.status"
STATE_FILE="/tmp/cert-expiry-monitor.email.state"
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
  name: cert-expiry-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cert-expiry-monitor
            image: alpine/bash
            command: ["/scripts/cert-expiry-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```


### Cron

```cron
0 8 * * * /opt/scripts/cert-expiry-monitor.sh >/dev/null 2>&1
```

Runs once a day at 08:00. All configuration lives in the script.

### Checkmk (local check)

```bash
cp cert-expiry-monitor.sh /usr/lib/check_mk_agent/local/cert-expiry-monitor.sh
```

Adapt the `alert()` function body for Checkmk-compatible output.

### Grafana / Prometheus (textfile collector)

Add Prometheus metrics inside `alert()`:

```bash
for entry in "${expiring[@]}"; do
    label="${entry%% *}"
    days="${entry##*(}"; days="${days%% *}"
    echo "cert_expiry_days{host=\"${HOST_ID}\",cert=\"${label}\"} ${days}" \
        >> /var/lib/node_exporter/cert-expiry.prom
done
```

### systemd timer

```ini
# /etc/systemd/system/cert-expiry-monitor.service
[Unit]
Description=Certificate expiry check

[Service]
Type=oneshot
ExecStart=/opt/scripts/cert-expiry-monitor.sh
```

```ini
# /etc/systemd/system/cert-expiry-monitor.timer
[Unit]
Description=Run certificate expiry check daily at 08:00

[Timer]
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now cert-expiry-monitor.timer
```

---

## Use cases

### WebLogic identity and trust keystores

Monitor both keystores of a WebLogic domain, using the JDK bundled with the middleware:

```bash
KEYTOOL_BIN="/opt/oracle/middleware/jdk/bin/keytool"

CERTS=(
    "keytool|/opt/weblogic/user_projects/domains/mydomain/identity.jks|changeit"
    "keytool|/opt/weblogic/user_projects/domains/mydomain/trust.jks|changeit"
)

THRESHOLD_DAYS=60
ALERT_EMAIL="weblogic-ops@company.com infra@company.com"
```

### Mixed infrastructure

Monitor a combination of public endpoints, internal services, on-disk files, and keystores:

```bash
KEYTOOL_BIN="/usr/java/jdk-21/bin/keytool"

CERTS=(
    "file|/etc/nginx/ssl/company.crt|"
    "host|api.company.com:443|"
    "host|internal-ldap.company.com:636|"
    "host|smtp.company.com:587|"
    "keytool|/opt/app/identity.jks|changeit"
    "keytool|/opt/app/trust.p12|mypassword"
)

THRESHOLD_DAYS=30
ALERT_EMAIL="ops@company.com security@company.com"
```

### Temporarily disabling an entry during rotation

During planned maintenance or certificate rotation, disable a specific entry without removing it:

```bash
CERTS=(
    "host|api.company.com:443|"
    ""                                         # identity.jks: rotating this week
    "keytool|/opt/app/trust.jks|changeit"
)
```

### Container / Kubernetes sidecar

Run as a CronJob that checks certificates mounted from a Secret:

```bash
CERTS=(
    "file|/etc/ssl/app/tls.crt|"
)
HOSTNAME_LABEL="k8s-cert-check-prod"
ERROR_LOG=""
EXECUTION_LOG=""
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cert-expiry-monitor
spec:
  schedule: "0 8 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: cert-expiry-monitor
            image: alpine:latest
            command: ["bash", "/opt/scripts/cert-expiry-monitor.sh"]
            volumeMounts:
            - name: script
              mountPath: /opt/scripts
              readOnly: true
            - name: tls
              mountPath: /etc/ssl/app
              readOnly: true
          volumes:
          - name: script
            configMap:
              name: cert-expiry-monitor-script
          - name: tls
            secret:
              secretName: app-tls
          restartPolicy: OnFailure
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `CERTS` | `("host\|example.com:443\|")` | Array of pipe-separated certificate descriptors. |
| `THRESHOLD_DAYS` | `30` | Alert when expiry is within this many days. |
| `KEYTOOL_BIN` | `""` *(auto-detect)* | Explicit path to `keytool`. Use when not in `$PATH`. |
| `OPENSSL_BIN` | `""` *(auto-detect)* | Explicit path to `openssl`. Use when not in `$PATH`. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/cert-expiry-monitor.email.state` | Last-email timestamp. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/cert-expiry-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/cert-expiry-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/cert-expiry-monitor.maintenance` | Maintenance mode marker. Managed by `--maintenance`. |
| `LOCK_FILE` | `<script_dir>/cert-expiry-monitor.lock` | Instance lock file for `flock`. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Resolve tool paths, show prerequisites and configuration, list all configured certificates, and preview actions without performing them. |
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
