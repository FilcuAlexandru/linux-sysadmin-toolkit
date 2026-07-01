# auditd-setup

Install auditd and deploy a baseline audit rules file.

---

## Purpose

Provides a consistent auditd baseline that records writes and attribute changes to sensitive identity files, supporting compliance and forensic readiness.

## What it does

- Installs auditd (package name resolved per distro).
- Deploys a rules file watching passwd/shadow/group/sudoers.
- Reloads rules with `augenrules --load` on change.

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
| `auditd_watch_files` | `(list)` | Files to watch with write/attr rules. |
| `auditd_rules_path` | `/etc/audit/rules.d/10-hardening.rules` | Rules file path. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini auditd-setup.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini auditd-setup.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini auditd-setup.yml --limit web -e 'auditd_watch_files=['/etc/passwd']'
```

---

## Idempotency & safety

- **Additive:** deploys a dedicated rules file under `rules.d`, leaving distro defaults intact.
- **Idempotent:** re-runs only change the file if a watched path changes.

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
