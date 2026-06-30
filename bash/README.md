<div align="center">

# Bash SysAdmin Toolkit

### 40 self-contained Bash scripts that watch a Linux system and alert when something is wrong

*One folder per task — read each script on its own and know exactly what it checks.*

![Bash](https://img.shields.io/badge/Bash-4.x%2B-4EAA25?logo=gnubash&logoColor=white)
![Scripts](https://img.shields.io/badge/scripts-40-success)
![Source](https://img.shields.io/badge/reads-%2Fproc%20%2F%20%2Fsys-informational)
![Schedule](https://img.shields.io/badge/runs_from-cron%20%2F%20systemd-blue)
![Distro](https://img.shields.io/badge/distro-agnostic-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

The `bash/` section is the **observe-and-alert** half of the toolkit. Each script checks one thing —
CPU, inodes, failed logins, RAID health, a TLS certificate — and raises an alert when a threshold is
crossed. Scripts are meant to run unattended from cron or a systemd timer and need nothing beyond
Bash; optional tools are used when present and skipped gracefully when not. Everything targets
**SLES, RHEL/Rocky/Alma, Ubuntu, and Debian** without distribution-specific assumptions.

---

## 1. The shared engine

Every script is built on the same skeleton, so once you know one you know them all:

- **Configuration at the top.** All tunables (thresholds, email, paths) live above a
  `no changes needed past this line` marker. You never edit the logic below it.
- **`--dry-run`.** Checks prerequisites and privileges, prints the configuration and current state,
  and previews the alert that *would* fire — without sending or changing anything.
- **`--maintenance`.** Toggles a maintenance flag that suppresses alerts during planned work.
- **`--version` / `--help`.** Self-documenting.
- **Status-aware alerting.** Alerts once when a problem appears, stays quiet while it persists, and
  sends a single recovery message when it clears.
- **Email with rate-limiting**, **instance locking** via `flock`, and **self-rotating logs** with a
  retention window.
- **Graceful degradation.** A missing optional tool downgrades a feature (no email, no locking) with a
  warning instead of failing the run.

Run from cron with nothing else on the line — all configuration lives in the script:

```cron
*/5 * * * * /opt/scripts/cpu-usage-monitor.sh >/dev/null 2>&1
```

---

## 2. The scripts

### CPU, memory & load

| Script | What it checks |
|---|---|
| `cpu-usage-monitor` | CPU usage vs a threshold; includes the top-5 processes in alert emails. |
| `memory-usage-monitor` | Memory usage vs a threshold. |
| `swap-monitor` | Swap usage vs a threshold. |
| `load-monitor` | Load average relative to the CPU core count. |

### Disk & storage

| Script | What it checks |
|---|---|
| `disk-usage-monitor` | Per-filesystem disk usage thresholds. |
| `inode-usage-monitor` | Per-filesystem inode usage — catches inode exhaustion byte-checks miss. |
| `mount-monitor` | Expected mount points are present. |
| `filesystem-readonly-monitor` | Detects filesystems remounted read-only (often a disk error). |
| `smart-disk-monitor` | Disk S.M.A.R.T. health via `smartctl`. |
| `raid-health-monitor` | Linux software RAID (md) array health from `/proc/mdstat`. |

### Processes

| Script | What it checks |
|---|---|
| `process-monitor` | Presence of one or more critical processes. |
| `zombie-process-monitor` | Count of zombie/defunct processes. |
| `open-files-monitor` | System-wide open file descriptors vs `fs.file-max`. |
| `oom-killer-monitor` | Recent OOM-killer activity in the kernel log. |

### Network

| Script | What it checks |
|---|---|
| `network-bandwidth-monitor` | Per-interface throughput in Mbit/s. |
| `interface-link-monitor` | Network interface link state (up/down) via sysfs. |
| `port-monitor` | Expected listening ports are open. |
| `conntrack-monitor` | netfilter connection-tracking table usage. |
| `dns-resolution-monitor` | DNS resolution health for a list of hostnames. |
| `url-health-monitor` | HTTP(S) endpoint health checks. |

### Services & systemd

| Script | What it checks |
|---|---|
| `service-start` | Starts a service idempotently. |
| `service-stop` | Stops a service idempotently. |
| `service-watchdog` | Restarts a service when it is found down. |
| `systemd-failed-monitor` | Detects failed systemd units. |
| `journal-usage-monitor` | systemd journal disk usage. |

### Security & access

| Script | What it checks |
|---|---|
| `failed-login-monitor` | Failed SSH login attempts. |
| `login-session-monitor` | Number of active interactive login sessions. |
| `ssh-config-audit` | sshd configuration hardening audit. |
| `firewall-status-monitor` | Verifies an active host firewall (firewalld/ufw/nftables/iptables). |
| `cert-expiry-monitor` | TLS certificate expiry. |
| `entropy-monitor` | Available kernel entropy pool. |

### Packages, time & inventory

| Script | What it checks |
|---|---|
| `installed-packages` | Installed-package inventory. |
| `package-update-monitor` | Pending package updates across apt/dnf/yum/zypper. |
| `reboot-required-monitor` | Pending-reboot detection (Debian/RHEL/SLES). |
| `ntp-sync-monitor` | Clock synchronization and offset. |
| `hardware-specs` | Hardware inventory snapshot. |

### Files & maintenance

| Script | What it does |
|---|---|
| `file-change-monitor` | Detects changes to watched files/directories. |
| `directory-backup` | Timestamped directory backups with retention. |
| `log-cleanup` | Retention-based cleanup of old log files. |
| `tmp-cleanup` | Cleanup of a temp directory with retention. |

---

## 3. Folder structure

Each script lives in its own folder with a dedicated README:

```
bash/
├── README.md                 this index
└── <task>/
    ├── <task>.sh             the script
    └── README.md             purpose, configuration, usage, exit codes
```

---

## 4. Requirements

- **Bash 4.x+** and a Linux `/proc` (and, where noted, `/sys`) filesystem — standard on every distro
  and container.
- Optional, used when present: `mail` (email alerts), `flock` (locking), `find` (log rotation), plus a
  few task-specific tools noted in each script's README (`smartctl`, `nft`/`ufw`, `inotifywait`, …).

---

## 5. Usage

```bash
# Preview prerequisites, configuration, and the alert that would fire.
./cpu-usage-monitor/cpu-usage-monitor.sh --dry-run

# Run it (typically from cron/systemd).
./inode-usage-monitor/inode-usage-monitor.sh

# Suppress alerts during planned maintenance, then re-enable.
./disk-usage-monitor/disk-usage-monitor.sh --maintenance
```

The action scripts (`service-start`, `service-stop`, `directory-backup`, `log-cleanup`,
`tmp-cleanup`) require a small amount of configuration (a service name or a path) at the top of the
script before a real run; until then they refuse to act and tell you what is missing.

---

## 6. Exit codes

| Exit code | Meaning |
|---|---|
| `0` | Normal completion — whether the result was OK **or** an alert was raised (cron stays quiet). |
| `0` | Another instance already holds the lock (silent exit to avoid overlap). |
| `1` | Usage error (unknown option) or an unrecoverable startup error. |

---

## 7. Quality checks

```bash
# Syntax-check every script.
for f in */*.sh; do bash -n "$f"; done

# Optional: static analysis.
shellcheck */*.sh
```

---

## Author

Filcu Alexandru

## License

MIT
