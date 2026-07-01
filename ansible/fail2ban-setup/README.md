# fail2ban-setup

Install Fail2ban and deploy an SSH jail policy.

---

## Purpose

Protects SSH (and optionally other services) from brute-force attacks by installing Fail2ban and enforcing a consistent ban policy across the fleet.

## What it does

- Installs Fail2ban and enables the service.
- Deploys a managed `jail.local` enabling the sshd jail with tunable thresholds.
- Restarts Fail2ban on policy change.

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
| `fail2ban_bantime` | `3600` | Ban duration in seconds. |
| `fail2ban_findtime` | `600` | Window for counting failures. |
| `fail2ban_maxretry` | `5` | Failures before a ban. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini fail2ban-setup.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini fail2ban-setup.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini fail2ban-setup.yml --limit web -e 'fail2ban_bantime=86400'
```

---

## Idempotency & safety

- **Dependency note:** on RHEL/Rocky/Alma, `fail2ban` lives in EPEL — enable it first (see `14-repo-management`).
- **Idempotent:** policy is file-managed; re-runs are no-ops when unchanged.

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
