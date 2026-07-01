# sysctl-hardening

Deploy a kernel hardening sysctl profile and reload it.

---

## Purpose

Applies a consistent set of network- and kernel-level hardening parameters through a single managed drop-in file, so the values survive reboots and are easy to audit.

## What it does

- Renders the sysctl keys from a variable into `/etc/sysctl.d/99-hardening.conf`.
- Reloads with `sysctl -p` via a handler only when the file changes.
- Tunable: add or override keys via the `sysctl_hardening` mapping.

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
| `sysctl_profile_path` | `/etc/sysctl.d/99-hardening.conf` | Drop-in file path. |
| `sysctl_hardening` | `(map)` | Mapping of sysctl key to value. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini sysctl-hardening.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini sysctl-hardening.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini sysctl-hardening.yml --limit web -e 'sysctl_hardening='{net.ipv4.ip_forward: 1}''
```

---

## Idempotency & safety

- **File-based & idempotent:** the profile is rendered from a variable; re-runs change nothing unless a value differs.
- **Reversible:** remove a key from the map (or the file) to revert.

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
