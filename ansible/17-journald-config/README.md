# 17-journald-config

Enforce journald storage, size cap, and retention.

---

## Purpose

Caps systemd journal disk usage and sets a retention window so logs are persistent yet bounded — preventing journals from filling a disk.

## What it does

- Sets `Storage`, `SystemMaxUse`, and `MaxRetentionSec` in `journald.conf`.
- Restarts `systemd-journald` only on change.
- All limits are variables.

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
| `journald_max_use` | `500M` | Max disk the journal may use. |
| `journald_max_retention` | `1month` | Retention window (MaxRetentionSec). |
| `journald_storage` | `persistent` | Journal storage mode. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini journald-config.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini journald-config.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini journald-config.yml --limit web -e 'journald_max_use=1G'
```

---

## Idempotency & safety

- **Bounded logs:** prevents unbounded journal growth.
- **Restart is light:** journald restarts without losing persisted logs.

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
