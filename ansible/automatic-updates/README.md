# automatic-updates

Configure unattended-upgrades (Debian) or dnf-automatic (RHEL).

---

## Purpose

Keeps hosts patched automatically using the package manager's native unattended mechanism for each distribution family.

## What it does

- Debian/Ubuntu: installs and enables `unattended-upgrades`.
- RHEL family: installs `dnf-automatic` and enables its systemd timer.
- Toggle via `auto_updates_enabled`.

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
| `auto_updates_enabled` | `true` | Enable (1) or disable (0) unattended upgrades. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini automatic-updates.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini automatic-updates.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini automatic-updates.yml --limit web -e 'auto_updates_enabled=true'
```

---

## Idempotency & safety

- **Family-aware:** each block runs only on the matching `ansible_os_family`.
- **SUSE:** not covered here; use `zypper` automatic patching separately.

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
