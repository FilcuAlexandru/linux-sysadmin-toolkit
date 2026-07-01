<div align="center">

# Python SysAdmin Toolkit

### 40 standard-library Python scripts that audit a Linux system and report JSON

*One folder per task — machine-readable output, ready for a monitoring pipeline.*

![Python](https://img.shields.io/badge/Python-3.6%2B-3776AB?logo=python&logoColor=white)
![Stdlib](https://img.shields.io/badge/dependencies-stdlib_only-success)
![Scripts](https://img.shields.io/badge/scripts-40-success)
![Output](https://img.shields.io/badge/output-JSON-blue)
![Exit codes](https://img.shields.io/badge/exit-0_OK_%2F_1_ALERT_%2F_2_ERROR-informational)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

The `python/` section is the **observe-and-report** half of the toolkit. Each script inspects one
aspect of the system and prints a **JSON document** on stdout, so the result can be piped straight
into a monitoring system, a dashboard, or `jq`. It uses **only the Python standard library** — no
`pip install`, no virtualenv — and runs on any host with Python 3.6+. Everything targets
**SLES, RHEL/Rocky/Alma, Ubuntu, and Debian**.

---

## 1. The shared engine

Every script follows the same pattern, so they are interchangeable in operation:

- **JSON on stdout.** A consistent envelope: `timestamp`, `host`, `script`, `version`, `status`,
  `data`, `alerts`, `duration_seconds`.
- **Exit codes.** `0` = OK, `1` = ALERT (one or more findings), `2` = ERROR (unexpected failure).
- **`--dry-run`.** Prints the configuration and current state — including `running_as_root` and any
  unmet prerequisites — without doing the work.
- **`--maintenance`** to suppress alerts, **`--version`** to print the version.
- **Status-aware alerting** with recovery, **email rate-limiting**, **instance locking** via `flock`,
  and **self-rotating logs** — the same operational behaviour as the Bash section.
- **All configuration lives at the top** of each file, above the
  `no changes needed past this line` marker; every function carries a short docstring describing what
  it does.

```bash
python3 system-monitor/system-monitor.py | jq .status
```

---

## 2. The scripts

### Core monitoring & metrics

| Folder | What it reports |
|---|---|
| `system-monitor` | CPU, memory, swap, disk, and network metrics in one run. |
| `disk-trend-analyzer` | Linear regression on disk history; ETA-to-full. |
| `network-monitor` | Per-interface throughput, errors, TCP/UDP states. |
| `process-monitor` | Process crashes, D-state, zombies, memory leaks. |
| `disk-io-monitor` | Per-disk read/write throughput from `/proc/diskstats`. |
| `network-connections-audit` | TCP connection-state histogram with saturation thresholds. |
| `capacity-forecast` | Linear time-to-full forecast per filesystem. |

### Security & access audits

| Folder | What it reports |
|---|---|
| `user-audit` | User risk scoring across passwd/shadow/sudoers. |
| `ssh-key-audit` | Weak SSH keys, duplicates, missing comments. |
| `open-ports-audit` | Listening ports vs. an expected list; port diff. |
| `failed-login-analyzer` | Failed SSH logins, top IPs, hourly heatmap. |
| `security-report` | Failed logins, open ports, risky users, sudo log. |
| `sudoers-audit` | NOPASSWD and broad-grant findings in sudoers. |
| `suid-audit` | SUID/SGID inventory and world-writable detection. |
| `listening-services-map` | Listening-socket map; flags wildcard exposure. |
| `tls-cert-scanner` | On-disk TLS certificate expiry scanning. |
| `file-integrity-monitor` | SHA-256 baselining of critical files. |

### Inventory & state

| Folder | What it reports |
|---|---|
| `system-snapshot` | Full system-state capture and diff. |
| `package-inventory` | Installed packages cross-distro; install diff. |
| `hardware-inventory` | CPU, memory, disks, interfaces, PCI devices. |
| `service-inventory` | systemd service states; failed-unit detection. |
| `kernel-module-audit` | Loaded-module inventory and kernel-taint detection. |
| `systemd-timer-audit` | systemd timer inventory; failed-timer detection. |
| `process-tree-snapshot` | Process inventory; runaway process-count alert. |

### Configuration & compliance

| Folder | What it reports |
|---|---|
| `cron-audit` | All crontabs inventoried; script-existence check. |
| `inode-usage-monitor` | Per-filesystem inode usage. |
| `ntp-sync-audit` | Clock sync and offset across chrony/ntpd/timesyncd. |
| `firewall-audit` | Detects an active firewall backend. |
| `mount-options-audit` | nosuid/nodev/noexec hardening on key mounts. |
| `dns-health-monitor` | DNS resolution success and latency per target. |
| `package-update-report` | Pending updates across apt/dnf/yum/zypper. |
| `logrotate-audit` | logrotate targets that match no files. |
| `sysctl-audit` | sysctl values vs. a hardening baseline. |

### Reports, analysis & operations

| Folder | What it does |
|---|---|
| `user-manager` | Add/remove/lock/unlock users with an audit trail. |
| `backup-manager` | rsync incremental backups with SHA-256 checks. |
| `log-analyzer` | Log patterns, error counts, spike detection. |
| `system-report` | Daily aggregated system report. |
| `disk-space-report` | Disk usage with ASCII bars and trend ETAs. |
| `performance-baseline` | Performance baseline capture and deviation alerts. |
| `memory-leak-detector` | Per-process RSS growth tracking across runs. |

---

## 3. Folder structure

Each script lives in its own folder with a dedicated README — the same layout as the `bash/` section:

```
python/
├── README.md                 this index
└── <task>/
    ├── <task>.py             the script
    └── README.md             purpose, configuration, usage, exit codes
```

---

## 4. Requirements

- **Python 3.6+** — standard library only, no third-party packages.
- A Linux host with the `/proc` filesystem. A few audits read root-only paths (e.g. `/etc/shadow`,
  crontab spools) and report what they could not read when run unprivileged.

---

## 5. Usage

Every script (except `user-manager`, which takes subcommands) follows the same pattern:

```bash
python3 <task>/<task>.py              # run; prints a JSON result
python3 <task>/<task>.py --dry-run    # show config + prerequisites, do nothing
python3 <task>/<task>.py --maintenance # toggle maintenance mode
python3 <task>/<task>.py --version    # print version
```

Output is always JSON on stdout. Combine with `jq` to extract fields:

```bash
python3 inode-usage-monitor/inode-usage-monitor.py | jq '.alerts'
```

---

## 6. Exit codes

| Exit code | Meaning |
|---|---|
| `0` | Completed with no alerts (`status: OK`), or the dry-run/maintenance/version paths. |
| `0` | Another instance already holds the lock (silent exit). |
| `1` | One or more alert conditions fired (`status: ALERT`). |
| `2` | An unhandled error occurred (`status: ERROR`); details are in the `alerts` array. |

---

## 7. Quality checks

```bash
# Compile every script (standard library only).
python3 -m py_compile */*.py

# Confirm each emits valid JSON.
for f in */*.py; do python3 "$f" >/dev/null || true; done
```

---

## Author

Filcu Alexandru

## License

MIT
