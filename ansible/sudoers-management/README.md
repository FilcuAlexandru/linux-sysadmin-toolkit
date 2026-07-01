# sudoers-management

Deploy /etc/sudoers.d entries validated with visudo.

---

## Purpose

Manages sudo grants as small, individually validated drop-in files under `/etc/sudoers.d`, so a malformed rule can never corrupt the main sudoers file.

## What it does

- One file per rule under `/etc/sudoers.d` (mode 0440).
- Every file is validated with `visudo -cf` before being saved.
- Rules are data in the `sudoers_rules` list.

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
| `sudoers_rules` | `(list)` | Each item has name and content (a sudoers line). |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini sudoers-management.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini sudoers-management.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini sudoers-management.yml --limit web -e 'target_hosts=all'
```

---

## Idempotency & safety

- **Validated:** `visudo -cf` rejects any syntactically invalid rule, so sudo stays usable.
- **Least privilege:** prefer `NOPASSWD` only for specific commands, as in the example.

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
