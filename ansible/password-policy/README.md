# password-policy

Configure login.defs aging and pwquality complexity rules.

---

## Purpose

Standardizes password aging and complexity across hosts: maximum age, warning window, minimum length, and character-class requirements via pam_pwquality.

## What it does

- Sets PASS_MAX_DAYS/MIN_DAYS/WARN_AGE in `login.defs`.
- Deploys `/etc/security/pwquality.conf` with length and credit rules.
- All thresholds are variables.

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
| `pass_max_days` | `90` | Maximum password age (days). |
| `pwquality_minlen` | `14` | Minimum password length. |
| `pwquality_dcredit` | `-1` | Require at least one digit (negative = required count). |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini password-policy.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini password-policy.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini password-policy.yml --limit web -e 'pwquality_minlen=16'
```

---

## Idempotency & safety

- **Aging applies to new passwords:** existing passwords keep their current expiry until changed.
- **pwquality requires** the pam_pwquality module (libpam-pwquality / libpwquality), present on modern distros.

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
