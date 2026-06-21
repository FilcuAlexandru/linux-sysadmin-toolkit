# network-bandwidth-monitor.sh

Lightweight Bash script that measures network throughput on a configured interface and alerts when inbound or outbound traffic exceeds a configurable threshold. Reads `/proc/net/dev` directly — no external tools required for measurement. Takes two samples a configurable interval apart and computes Mbit/s using awk.

---

## Features

- **Kernel-direct measurement** — reads raw byte counters from `/proc/net/dev`; no `ifstat`, `vnstat`, or `iftop` needed.
- **Both directions** — monitors RX (inbound) and TX (outbound) independently; alerts when either exceeds the threshold.
- **Configurable sample interval** — `SAMPLE_INTERVAL` controls the gap between the two `/proc/net/dev` reads (default: 2 seconds). Longer intervals give more stable averages.
- **Counter wrap protection** — guards against the (rare) 64-bit byte counter wrap returning a negative delta.
- **Status tracking** — alerts once when throughput goes above the threshold, stays silent while it remains high, and sends a recovery email when both directions drop back below.
- **Maintenance mode** — toggle with `--maintenance`; suppresses all alerts while active.
- **Instance locking** — prevents overlapping runs via `flock(1)`, with graceful skip when unavailable.
- **Email alerts with rate-limiting** — optional notifications via `mail(1)`, throttled to a configurable interval (default: 1 per hour). Supports multiple recipients.
- **Structured logging** — optional execution log (every run) and error log (only issues), with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` verifies the interface exists in `/proc/net/dev` and shows the full configuration before taking a live sample.
- **Monitoring integration** — `alert()` function designed as a seam for Checkmk, Grafana, Prometheus, or any external system.
- **Container-ready** — custom hostname labels, graceful degradation on read-only filesystems.
- **Self-contained configuration** — all settings live inside the script; cron entries stay clean.
- **Distro-agnostic** — requires only Bash and a Linux kernel with `/proc` mounted.

---

## Requirements

- **Bash 4.x+**
- **Linux kernel with `/proc/net/dev`** — present on all Linux systems and standard containers.
- **`sleep`** — required for the sampling interval (part of `coreutils`, always available).

Optional (the script warns and continues without them):

- **`mail` command** — for email alerts (`mailutils`, `s-nail`, or similar).
- **A configured MTA/relay** — for email delivery (Postfix, msmtp, ssmtp, etc.).
- **`flock`** — for instance locking (`util-linux`).
- **`find`** — for log rotation (`findutils`).

---

## Installation

### From Git (recommended)

```bash
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/network-bandwidth-monitor/network-bandwidth-monitor.sh \
     -o /opt/scripts/network-bandwidth-monitor.sh

wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/bash/network-bandwidth-monitor/network-bandwidth-monitor.sh \
     -O /opt/scripts/network-bandwidth-monitor.sh
```

### Manual copy

```bash
cp network-bandwidth-monitor.sh /opt/scripts/network-bandwidth-monitor.sh
chmod +x /opt/scripts/network-bandwidth-monitor.sh
```

### Verify

```bash
/opt/scripts/network-bandwidth-monitor.sh --version
/opt/scripts/network-bandwidth-monitor.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. The script logic lives below a clearly marked separator line — you never need to edit anything below it.

### Interface and threshold

```bash
INTERFACE="eth0"
THRESHOLD_MBPS="100"
SAMPLE_INTERVAL="2"
```

| Variable | Default | Description |
|---|---|---|
| `INTERFACE` | `eth0` | Network interface to monitor. Must exist in `/proc/net/dev`. |
| `THRESHOLD_MBPS` | `100` | Alert when RX or TX exceeds this value in Mbit/s. |
| `SAMPLE_INTERVAL` | `2` | Seconds between the two `/proc/net/dev` reads. |

#### Finding the correct interface name

```bash
# List all interfaces
cat /proc/net/dev | awk 'NR>2 {gsub(/:/, "", $1); print $1}'

# Or with ip
ip link show | awk '/^[0-9]+:/ {gsub(/:/, "", $2); print $2}'
```

Common interface names:

| Environment | Typical name |
|---|---|
| Bare metal / VM | `eth0`, `ens3`, `ens18`, `enp0s3` |
| Docker container | `eth0` |
| Kubernetes pod | `eth0` |
| Bonded interface | `bond0` |
| VLAN | `eth0.100` |
| Loopback (not useful) | `lo` |

#### Tuning `THRESHOLD_MBPS`

| Scenario | `THRESHOLD_MBPS` | Notes |
|---|---|---|
| 100 Mbit uplink | `80` | Alert at 80% of link capacity |
| 1 Gbit uplink | `800` | Alert at 80% of link capacity |
| 10 Gbit uplink | `8000` | Alert at 80% of link capacity |
| Application-level quota | `50` | Alert when app generates more than 50 Mbit/s |

#### Tuning `SAMPLE_INTERVAL`

| Value | Behaviour |
|---|---|
| `1` | Fastest measurement; noisier on bursty traffic |
| `2` *(default)* | Good balance between speed and accuracy |
| `5` | Smoother average; script takes 5 seconds per run |
| `10` | Very stable; appropriate for cron runs every minute |

Note: the script blocks for `SAMPLE_INTERVAL` seconds on every run. Keep this in mind when setting the cron frequency.

### Email alerts

```bash
ALERT_EMAIL=""
EMAIL_INTERVAL="3600"
STATE_FILE="${SCRIPT_DIR}/network-bandwidth-monitor.email.state"
```

| Variable | Default | Description |
|---|---|---|
| `ALERT_EMAIL` | `""` *(disabled)* | One or more recipients, space-separated. Leave empty to disable. |
| `EMAIL_INTERVAL` | `3600` (1 hour) | Minimum seconds between alert emails. Console alerts are always shown. |
| `STATE_FILE` | `<script_dir>/network-bandwidth-monitor.email.state` | Stores the timestamp of the last sent email. |

#### Single recipient

```bash
ALERT_EMAIL="ops@example.com"
```

#### Multiple recipients

```bash
ALERT_EMAIL="ops@example.com infra@example.com"
```

### Logging

```bash
LOG_DIR="${SCRIPT_DIR}/logs"
ERROR_LOG="${LOG_DIR}/network-bandwidth-monitor-error.log"
EXECUTION_LOG="${LOG_DIR}/network-bandwidth-monitor-execution.log"
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_DIR` | `<script_dir>/logs/` | Directory for log files. Auto-created if missing. |
| `ERROR_LOG` | `<LOG_DIR>/network-bandwidth-monitor-error.log` | Alerts and recoveries only. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/network-bandwidth-monitor-execution.log` | Every run (RX/TX/result). `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` (two weeks) | Rotate and prune logs older than this. `0` = keep forever. |

### Host identification

```bash
HOSTNAME_LABEL=""
```

```bash
HOSTNAME_LABEL="gateway-prod-01"
```

### Maintenance, locking, and status

```bash
MAINTENANCE_FILE="${SCRIPT_DIR}/network-bandwidth-monitor.maintenance"
LOCK_FILE="${SCRIPT_DIR}/network-bandwidth-monitor.lock"
STATUS_FILE="${SCRIPT_DIR}/network-bandwidth-monitor.status"
```

These are managed automatically.

---

## Usage

```
Usage: network-bandwidth-monitor.sh [--dry-run] [--maintenance] [--version] [--help]

Options:
  --dry-run       Check prerequisites and preview all actions without performing them
  --maintenance   Toggle maintenance mode (suppresses alerts while active)
  --version       Show version and exit
  --help          Show this help and exit
```

### Basic run

```bash
./network-bandwidth-monitor.sh
```

Below threshold:

```
Bandwidth [eth0]:  RX: 12.45 Mbit/s  TX: 3.21 Mbit/s  (threshold: 100 Mbit/s)
```

Above threshold:

```
Bandwidth [eth0]:  RX: 143.72 Mbit/s  TX: 8.91 Mbit/s  (threshold: 100 Mbit/s)
ALERT: High bandwidth on eth0 on gateway-prod-01: RX: 143.72 Mbit/s  TX: 8.91 Mbit/s  (threshold: 100 Mbit/s)
```

RX and TX are highlighted red when above threshold (on terminals).

### Dry-run

```bash
./network-bandwidth-monitor.sh --dry-run
```

```
Prerequisites:
  /proc/net/dev                OK
  Interface eth0               OK
  sleep                        OK
  mail                         OK
  flock                        OK
  find                         OK

Configuration:
  Host ID:                     gateway-prod-01
  Interface:                   eth0
  Threshold:                   100 Mbit/s
  Sample interval:             2 s
  E-Mail:                      ops@example.com
  E-Mail interval:             3600s
  ...

State:
  Current status:              OK
  Maintenance mode:            off
  Last email:                  never
  Lock directory writable:     OK

Bandwidth [eth0]:  RX: 12.45 Mbit/s  TX: 3.21 Mbit/s  (threshold: 100 Mbit/s)
```

The dry-run takes a live sample — it still waits `SAMPLE_INTERVAL` seconds.

### Maintenance mode

```bash
./network-bandwidth-monitor.sh --maintenance
# Output: Maintenance mode enabled

./network-bandwidth-monitor.sh --maintenance
# Output: Maintenance mode disabled
```

---

## How it works

### Measurement method

`/proc/net/dev` exposes cumulative byte counters per interface since boot. The script reads the counters twice, `SAMPLE_INTERVAL` seconds apart, and computes throughput:

```
rx_mbps = (rx_bytes₂ - rx_bytes₁) × 8 / (SAMPLE_INTERVAL × 1_000_000)
tx_mbps = (tx_bytes₂ - tx_bytes₁) × 8 / (SAMPLE_INTERVAL × 1_000_000)
```

The `/proc/net/dev` line format:

```
  eth0: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts ...
         $2                                    $10
```

`$2` is `rx_bytes`, `$10` is `tx_bytes` (9 RX fields follow the colon before TX starts). All arithmetic is done in `awk` — Bash integers cannot handle large byte counters reliably.

### Counter wrap protection

On 64-bit kernels the byte counters are unsigned 64-bit integers (max ~18.4 exabytes). Wrap is practically impossible during a 2-second interval, but the script guards against it:

```bash
if (rx_bytes < 0) rx_bytes = 0
if (tx_bytes < 0) tx_bytes = 0
```

### Alert lifecycle

```
                    ┌─────────────┐
                    │  status=OK  │
                    └──────┬──────┘
                           │
              RX or TX > THRESHOLD_MBPS (first detection)
                           │
                    ┌──────▼──────┐
                    │ ALERT email │ ──► set status=ALERT
                    └──────┬──────┘
                           │
              still above threshold (subsequent runs)
                           │
                    ┌──────▼──────┐
                    │   silent    │ ──► "Already in ALERT state" (logged)
                    └──────┬──────┘
                           │
              both RX and TX <= THRESHOLD_MBPS
                           │
                    ┌──────▼────────┐
                    │RECOVERY email │ ──► set status=OK
                    └───────────────┘
```

---

## Logging

### Directory structure

```
scripts/
├── network-bandwidth-monitor.sh
├── network-bandwidth-monitor.status
├── network-bandwidth-monitor.email.state
├── network-bandwidth-monitor.lock
├── network-bandwidth-monitor.maintenance
└── logs/
    ├── network-bandwidth-monitor-error.log
    └── network-bandwidth-monitor-execution.log
```

### Execution log

```
2026-06-20 10:00:01 START [gateway-prod-01] iface=eth0 threshold=100Mbps interval=2s
2026-06-20 10:00:03 RESULT rx=12.45Mbps tx=3.21Mbps threshold=100Mbps (ok)
2026-06-20 10:00:03 END
2026-06-20 10:05:01 START [gateway-prod-01] iface=eth0 threshold=100Mbps interval=2s
2026-06-20 10:05:03 RESULT rx=143.72Mbps tx=8.91Mbps threshold=100Mbps (above)
2026-06-20 10:05:03 END
```

### Error log

```
2026-06-20 10:05:03 ALERT RX: 143.72 Mbit/s  TX: 8.91 Mbit/s  (threshold: 100 Mbit/s)
2026-06-20 10:05:03 EMAIL sent to ops@example.com
2026-06-20 10:45:03 RECOVERY EMAIL sent to ops@example.com
```

---

## Integration

### Cron

```cron
*/5 * * * * /opt/scripts/network-bandwidth-monitor.sh >/dev/null 2>&1
```

Each cron run takes `SAMPLE_INTERVAL` seconds (default 2s) to complete. This is normal — the script blocks during sampling.

### Container usage (Kubernetes / Docker)

`/proc/net/dev` is available inside containers by default. The interface name inside a container is typically `eth0`.

```bash
INTERFACE="eth0"
HOSTNAME_LABEL="app-prod-01"
```

On read-only container filesystems, point state files to a writable volume:

```bash
STATUS_FILE="/tmp/network-bandwidth-monitor.status"
STATE_FILE="/tmp/network-bandwidth-monitor.email.state"
LOG_DIR="/tmp/logs"
```

Example Kubernetes CronJob:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: network-bandwidth-monitor
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: network-bandwidth-monitor
            image: alpine/bash
            command: ["/scripts/network-bandwidth-monitor.sh"]
            env:
            - name: HOSTNAME_LABEL
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          restartPolicy: OnFailure
```

### Checkmk (local check)

```bash
cp network-bandwidth-monitor.sh /usr/lib/check_mk_agent/local/network-bandwidth-monitor.sh
```

### Grafana / Prometheus (textfile collector)

```bash
echo "network_rx_mbps{host=\"${HOST_ID}\",iface=\"${INTERFACE}\"} ${rx_mbps}" \
    > /var/lib/node_exporter/network-bandwidth.prom
echo "network_tx_mbps{host=\"${HOST_ID}\",iface=\"${INTERFACE}\"} ${tx_mbps}" \
    >> /var/lib/node_exporter/network-bandwidth.prom
```

### systemd timer

```ini
# /etc/systemd/system/network-bandwidth-monitor.service
[Unit]
Description=Network bandwidth monitor check

[Service]
Type=oneshot
ExecStart=/opt/scripts/network-bandwidth-monitor.sh
```

```ini
# /etc/systemd/system/network-bandwidth-monitor.timer
[Unit]
Description=Run network bandwidth monitor every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
```

---

## Use cases

### Server with a 100 Mbit uplink

Alert when approaching link capacity:

```bash
INTERFACE="eth0"
THRESHOLD_MBPS="80"
ALERT_EMAIL="ops@company.com"
```

### High-throughput transfer server

```bash
INTERFACE="ens3"
THRESHOLD_MBPS="800"   # 80% of 1 Gbit
ALERT_EMAIL="ops@company.com"
SAMPLE_INTERVAL="5"    # smoother average for bursty workloads
```

### Gateway / router monitoring

```bash
INTERFACE="eth1"       # WAN interface
THRESHOLD_MBPS="50"    # constrained uplink
HOSTNAME_LABEL="gw-prod"
ALERT_EMAIL="noc@company.com"
EMAIL_INTERVAL="1800"  # alert every 30 min while above threshold
```

### Multiple interfaces

Maintain separate script copies per interface:

```
/opt/scripts/
├── bw-monitor-eth0.sh    # INTERFACE=eth0 (public)
├── bw-monitor-eth1.sh    # INTERFACE=eth1 (private)
```

```cron
*/5 * * * * /opt/scripts/bw-monitor-eth0.sh >/dev/null 2>&1
*/5 * * * * /opt/scripts/bw-monitor-eth1.sh >/dev/null 2>&1
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `INTERFACE` | `eth0` | Network interface to monitor. |
| `THRESHOLD_MBPS` | `100` | Alert when RX or TX exceeds this value in Mbit/s. |
| `SAMPLE_INTERVAL` | `2` | Seconds between the two `/proc/net/dev` reads. |
| `ALERT_EMAIL` | `""` *(disabled)* | Space-separated list of email recipients. |
| `EMAIL_INTERVAL` | `3600` | Seconds between alert emails. |
| `STATE_FILE` | `<script_dir>/network-bandwidth-monitor.email.state` | Last-email timestamp file. |
| `LOG_DIR` | `<script_dir>/logs/` | Log directory. |
| `ERROR_LOG` | `<LOG_DIR>/network-bandwidth-monitor-error.log` | Error/alert log. `""` = disabled. |
| `EXECUTION_LOG` | `<LOG_DIR>/network-bandwidth-monitor-execution.log` | Execution log. `""` = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep logs. `0` = keep forever. |
| `HOSTNAME_LABEL` | `""` *(auto-detect)* | Custom hostname for alerts and logs. |
| `MAINTENANCE_FILE` | `<script_dir>/network-bandwidth-monitor.maintenance` | Maintenance mode marker. |
| `LOCK_FILE` | `<script_dir>/network-bandwidth-monitor.lock` | Instance lock file for `flock`. |
| `STATUS_FILE` | `<script_dir>/network-bandwidth-monitor.status` | Tracks OK/ALERT state. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Verify interface, show configuration, take a live sample — without alerting. Blocks for `SAMPLE_INTERVAL` seconds. |
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