# system-update-reboot

Apply all package updates and reboot only when needed and allowed.

---

## Purpose

Performs full system patching per distro family and reboots only when the OS reports a reboot is required and the operator has explicitly permitted it.

## What it does

- Updates packages via `apt`/`dnf`/`zypper` based on `ansible_os_family`.
- Detects a required reboot (`/var/run/reboot-required` or `needs-restarting -r`).
- Reboots only when `allow_reboot=true` and a reboot is actually needed.

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
| `allow_reboot` | `false` | Must be true to permit an automatic reboot. |
| `reboot_timeout` | `600` | Seconds to wait for the host to return. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini system-update-reboot.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini system-update-reboot.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini system-update-reboot.yml --limit web -e 'allow_reboot=true'
```

---

## Idempotency & safety

- **Reboot is opt-in:** nothing reboots unless `allow_reboot=true` AND the OS signals a reboot is required.
- **Builtin-only:** SUSE patching uses `zypper` via the command module so no extra collections are required.
- **Run in maintenance windows** and use `--check` to preview the update scope.

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
