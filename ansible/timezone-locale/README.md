# timezone-locale

Configure the system timezone and default locale idempotently.

---

## Purpose

Standardizes timezone and locale across hosts. The timezone is only changed when it actually differs, keeping runs idempotent and quiet.

## What it does

- Reads the current timezone and only calls `timedatectl set-timezone` on a mismatch.
- Writes `/etc/locale.conf` with the desired `LANG`.
- Both values are variables.

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
| `system_timezone` | `UTC` | IANA timezone name (e.g. Europe/Berlin). |
| `system_locale` | `en_US.UTF-8` | Default LANG locale. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini timezone-locale.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini timezone-locale.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini timezone-locale.yml --limit web -e 'system_timezone=Europe/Bucharest'
```

---

## Idempotency & safety

- **Idempotent timezone:** the set command runs only when the current zone differs.
- **Locale generation:** ensure the locale is generated (e.g. `locale-gen`) on minimal images.

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
