# cron-jobs

Declaratively manage cron jobs with the builtin cron module.

---

## Purpose

Manages scheduled jobs as data. Each entry is identified by name, so jobs can be added, changed, or removed idempotently without duplicating crontab lines.

## What it does

- Creates/updates/removes jobs with the builtin `cron` module.
- Per-job schedule fields default to `*`.
- Set `state: absent` on an entry to remove it.

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
| `cron_jobs` | `(list)` | Each: name, schedule fields, job, user, state. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini cron-jobs.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini cron-jobs.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini cron-jobs.yml --limit web -e 'target_hosts=batch'
```

---

## Idempotency & safety

- **Name-keyed:** changing a job's schedule updates the existing entry rather than adding a duplicate.
- **Removal is explicit:** entries are only deleted when `state: absent`.

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
