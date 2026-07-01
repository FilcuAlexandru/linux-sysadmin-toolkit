# repo-management

Configure apt/yum repositories declaratively per distro family.

---

## Purpose

Centralizes package-source configuration: define an APT line or a YUM repo and apply it to the right hosts based on their distribution family.

## What it does

- Debian/Ubuntu: manages an APT source via `apt_repository` (refreshes the cache).
- RHEL family: writes a `.repo` via `yum_repository` with GPG checking.
- All repo fields are variables.

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
| `apt_repo_line` | `(deb …)` | APT source line. |
| `yum_repo_baseurl` | `(url)` | Base URL for the YUM/DNF repo. |
| `yum_repo_gpgcheck` | `true` | Enforce GPG signature checking. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini repo-management.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini repo-management.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini repo-management.yml --limit web -e 'yum_repo_name=epel'
```

---

## Idempotency & safety

- **Keep GPG checking on:** `yum_repo_gpgcheck=true` by default; disabling it is insecure.
- **Example URLs are placeholders** — set real, trusted repository URLs.

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
