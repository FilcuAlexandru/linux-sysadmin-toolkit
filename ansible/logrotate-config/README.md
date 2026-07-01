# logrotate-config

Ensure logrotate is installed and deploy an application log policy.

---

## Purpose

Provides a consistent, declarative logrotate policy for an application's logs so they are rotated, retained for a fixed window, and compressed.

## What it does

- Installs logrotate.
- Deploys `/etc/logrotate.d/<app>` rendered from variables.
- Tunable frequency, retention count, and compression.

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
| `logrotate_log_glob` | `/var/log/myapp/*.log` | Glob of logs to rotate. |
| `logrotate_rotate_count` | `14` | Number of rotations to keep. |
| `logrotate_frequency` | `daily` | Rotation frequency. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini logrotate-config.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini logrotate-config.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini logrotate-config.yml --limit web -e 'logrotate_app_name=nginx'
```

---

## Idempotency & safety

- **copytruncate** is used so long-running processes need no reload.
- **Scoped:** affects only the configured glob, not other logrotate policies.

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
