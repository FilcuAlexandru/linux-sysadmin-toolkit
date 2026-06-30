# 15-ntp-time-sync

Install chrony and enforce a managed NTP server list.

---

## Purpose

Ensures accurate, consistent time across the fleet using chrony, with a managed server list and the correct config path/service name for each distribution.

## What it does

- Installs chrony and enables the service (name resolved per distro).
- Renders `chrony.conf` from the `ntp_servers` list.
- Restarts chrony only on change.

---

## Requirements

- **Ansible** 2.12+ (`ansible-core`) on the control node.
- **Target hosts:** Debian/Ubuntu, RHEL/Rocky/AlmaLinux, or SUSE/SLES with Python installed.
- **Privilege escalation:** the play uses `become: true` (root via sudo). Run with a user that
  can escalate, or pass `--ask-become-pass`.

## Variables

All variables have safe defaults and can be overridden with `-e` or in inventory/group_vars.

| Variable | Default | Description |
|---|---|---|
| `ntp_servers` | `(list)` | NTP servers to sync from. |
| `chrony_config_path` | `(auto)` | Config path, auto-selected per distro. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini ntp-time-sync.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini ntp-time-sync.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini ntp-time-sync.yml --limit web -e 'ntp_servers=['time.example.com']'
```

---

## Idempotency & safety

- **Single source of truth:** the rendered config replaces ad-hoc edits; review before applying if hosts have custom chrony settings.
- **Idempotent** and restart-on-change only.

- **Idempotent:** re-running makes no changes once the system is in the desired state.
- **Check-mode safe:** supports `--check`/`--diff` to preview changes.
- **Cross-distro:** package names and service units are selected per `ansible_os_family`.

---

## Exit behavior

| Result | Meaning |
|---|---|
| `ok` / `changed=0` | System already in desired state (idempotent no-op). |
| `changed>0` | Configuration was applied; handlers ran as needed. |
| `failed` | A task failed; the play stops for that host. Re-run after fixing the cause. |

---

## Author

**Filcu Alexandru**

## License

MIT
