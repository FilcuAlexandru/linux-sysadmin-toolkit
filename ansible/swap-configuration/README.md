# swap-configuration

Create and enable a swap file idempotently.

---

## Purpose

Adds a swap file of a defined size, formats and enables it, and persists it in fstab — all guarded so an existing swap file is never re-created or re-formatted.

## What it does

- Creates the file only if missing (`creates:` / stat guard).
- Sets 0600, formats with `mkswap`, enables with `swapon`.
- Persists via an fstab entry.

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
| `swap_file_path` | `/swapfile` | Path of the swap file. |
| `swap_file_size_mb` | `2048` | Swap file size in MB. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini swap-configuration.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini swap-configuration.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini swap-configuration.yml --limit web -e 'swap_file_size_mb=4096'
```

---

## Idempotency & safety

- **Idempotent & guarded:** formatting and `swapon` run only when the file did not already exist, so existing swap is untouched.
- **Size is fixed at creation:** to resize, disable and remove the old file first.

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
