# Python SysAdmin Toolkit

20 stdlib-only Python scripts for Linux OS administration.
Each script in its own folder with a dedicated README.

## Scripts

| # | Folder | Description |
|---|---|---|
| 01 | 01-system-monitor       | CPU, memory, swap, disk, and network metrics |
| 02 | 02-disk-trend-analyzer  | Linear regression on disk history; ETA-to-full |
| 03 | 03-network-monitor      | Per-interface throughput, errors, TCP/UDP states |
| 04 | 04-process-monitor      | Process crashes, D-state, zombies, memory leaks |
| 05 | 05-user-audit           | User risk scoring across passwd/shadow/sudoers |
| 06 | 06-ssh-key-audit        | Weak SSH keys, duplicates, missing comments |
| 07 | 07-open-ports-audit     | Listening ports vs. expected list, port diff |
| 08 | 08-failed-login-analyzer| Failed SSH logins, top IPs, hourly heatmap |
| 09 | 09-system-snapshot      | Full system state capture and diff |
| 10 | 10-package-inventory    | Installed packages cross-distro, install diff |
| 11 | 11-hardware-inventory   | CPU, memory, disks, interfaces, PCI devices |
| 12 | 12-service-inventory    | Systemd service states, failed unit detection |
| 13 | 13-user-manager         | Add/remove/lock/unlock users with audit trail |
| 14 | 14-backup-manager       | rsync incremental backups with SHA-256 checks |
| 15 | 15-log-analyzer         | Log patterns, error counts, spike detection |
| 16 | 16-cron-audit           | All crontabs inventoried, script existence check |
| 17 | 17-system-report        | Daily aggregated system report |
| 18 | 18-disk-space-report    | Disk usage with ASCII bars and trend ETAs |
| 19 | 19-security-report      | Failed logins, open ports, risky users, sudo log |
| 20 | 20-performance-baseline | Performance baseline capture and deviation alerts |

## Requirements

- Python 3.6+ (standard library only — no pip installs needed)
- Linux with `/proc` filesystem

## Usage

Every script (except user-manager) follows the same pattern:

```bash
python3 <script>.py              # run, output JSON
python3 <script>.py --dry-run    # show config without running
python3 <script>.py --maintenance # toggle maintenance mode
python3 <script>.py --version    # print version
```

Output is always JSON on stdout. Exit codes: 0=OK, 1=ALERT, 2=ERROR.

## Author

Filcu Alexandru

## License

MIT
