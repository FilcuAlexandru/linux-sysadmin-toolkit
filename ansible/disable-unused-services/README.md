# disable-unused-services

Stop, disable, and mask risky or unused services if present.

---

## Purpose

Reduces attack surface by ensuring legacy or unnecessary services are stopped and disabled — without failing on hosts where a given service is not installed.

## What it does

- Collects `service_facts` first to know what exists.
- Stops and disables each listed service only when present.
- Service list is fully configurable.

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
| `disable_services` | `(list)` | Service/unit names to stop and disable if present. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini disable-unused-services.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini disable-unused-services.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini disable-unused-services.yml --limit web -e 'disable_services=['cups']'
```

---

## Idempotency & safety

- **Safe on any host:** the `when: item in ansible_facts.services` guard skips services that are not installed.
- **Review the list:** make sure nothing you depend on is included before applying.

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
