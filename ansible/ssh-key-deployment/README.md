# ssh-key-deployment

Append authorized SSH public keys for existing accounts.

---

## Purpose

Distributes one or more SSH public keys to an existing account, appending them safely so previously authorized keys remain in place.

## What it does

- Ensures `~/.ssh` exists with correct ownership and 0700.
- Appends each key with `lineinfile` (no duplicates, no removals).
- Key list provided via `ssh_authorized_keys`.

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
| `ssh_key_target_user` | `deploy` | Account to receive the keys. |
| `ssh_authorized_keys` | `[]` | List of public key strings to authorize. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini ssh-key-deployment.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini ssh-key-deployment.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini ssh-key-deployment.yml --limit web -e 'ssh_key_target_user=admin'
```

---

## Idempotency & safety

- **Additive only:** existing keys are never removed.
- **Provide keys** via vault or `-e @keys.yml`; the default list is empty (no-op).

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
