# package-baseline

Ensure baseline packages are present and unwanted ones absent.

---

## Purpose

Guarantees a consistent software baseline: a defined set of tools is always present and a blacklist of risky/legacy packages is always removed.

## What it does

- Installs `packages_present` and removes `packages_absent` in two idempotent tasks.
- Uses the generic `package` module so it works on apt/dnf/zypper.
- Both lists are variables.

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
| `packages_present` | `(list)` | Packages to ensure installed. |
| `packages_absent` | `[telnet]` | Packages to ensure removed. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini package-baseline.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini package-baseline.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini package-baseline.yml --limit web -e 'packages_present=['vim','git']'
```

---

## Idempotency & safety

- **Name portability:** package names that differ across distros should be set per `ansible_os_family` (override the list in group_vars).
- **Idempotent:** no action when the baseline already matches.

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
