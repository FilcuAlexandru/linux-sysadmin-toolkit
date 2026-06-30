# 09-user-management

Create/manage local users with groups, shell, and authorized keys.

---

## Purpose

Manages local accounts as data: define users, their groups, login shell, and SSH public key in one list and apply the same state everywhere.

## What it does

- Creates groups and users idempotently with the builtin `group`/`user` modules.
- Provisions `~/.ssh/authorized_keys` (mode 0600) for users that define a key.
- Drives everything from the `managed_users` / `managed_groups` variables.

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
| `managed_users` | `(list)` | Users: name, groups, shell, ssh_key. |
| `managed_groups` | `[ops]` | Groups to create. |
| `managed_users_state` | `present` | present or absent for the listed users. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini user-management.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini user-management.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini user-management.yml --limit web -e 'managed_users_state=present'
```

---

## Idempotency & safety

- **Set `managed_users_state=absent` carefully:** it removes the listed accounts.
- **Home dirs are created** but never deleted by this play.

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
