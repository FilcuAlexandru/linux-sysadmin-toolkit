# user-management

Create/manage local users with groups, shell, and authorized keys.

---

## Features

- Creates groups and users idempotently with the builtin `group`/`user` modules.
- Provisions `~/.ssh/authorized_keys` (mode 0600) for users that define a key.
- Drives everything from the `managed_users` / `managed_groups` variables.
- **Idempotent** — re-running makes no changes once the host is in the desired state.
- **Check-mode safe** — supports `--check`/`--diff` to preview every change before applying.
- **Cross-distro** — package names, service units, and paths are selected per `ansible_os_family` (Debian/Ubuntu, RHEL/Rocky/Alma, SUSE/SLES).
- **`ansible.builtin` only** — no extra collections to install.
- **Fully variable-driven** — every tunable has a safe default and can be overridden with `-e` or in `group_vars/`.
- **Guarded** — destructive steps are protected, and configuration edits are validated before being applied where the tool allows it (`sshd -t`, `visudo -cf`, `nft -c`).

---

## Requirements

- **Control node:** `ansible-core` 2.12+ — no extra collections required (`ansible.builtin` only).
- **Managed nodes:** Debian/Ubuntu, RHEL/Rocky/AlmaLinux, or SUSE/SLES with Python 3.
- **Privilege escalation:** the play uses `become: true` (root via sudo). Run with a user that can
  escalate, or pass `--ask-become-pass`.

---

## Installation

### From Git (recommended)

```bash
git clone https://github.com/YOUR_USER/linux-sysadmin-toolkit.git
cd linux-sysadmin-toolkit/ansible

# Copy the sample inventory and edit it for your environment.
cp inventory.example.ini inventory.ini
```

### Standalone

```bash
# A playbook needs only its own folder plus an inventory.
ansible-playbook -i inventory.ini user-management/user-management.yml --check
```

---

## Variables

All variables have safe defaults and can be overridden with `-e` on the command line, or in
`group_vars/` / `host_vars/`.

| Variable | Default | Description |
|---|---|---|
| `managed_users` | `(list)` | Users: name, groups, shell, ssh_key. |
| `managed_groups` | `[ops]` | Groups to create. |
| `managed_users_state` | `present` | present or absent for the listed users. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

### Overriding variables

```bash
# Inline, for a single run.
ansible-playbook -i inventory.ini user-management/user-management.yml -e 'managed_users_state=present'
```

```yaml
# Persistently, in group_vars/all.yml (applies to every host):
managed_users_state: present
```

---

## Usage

```bash
# 1) Always preview first — shows exactly what would change, changes nothing.
ansible-playbook -i inventory.ini user-management/user-management.yml --check --diff

# 2) Apply to every host in the inventory.
ansible-playbook -i inventory.ini user-management/user-management.yml

# 3) Limit to a host group.
ansible-playbook -i inventory.ini user-management/user-management.yml --limit web

# 4) Prompt for the sudo password when the login user needs it.
ansible-playbook -i inventory.ini user-management/user-management.yml --ask-become-pass
```

A typical `PLAY RECAP` after a first apply:

```
PLAY RECAP *********************************************************************
web01  : ok=4  changed=2  unreachable=0  failed=0  skipped=0
```

Re-running immediately afterwards shows `changed=0` — proof the play is idempotent.

---

## How it works

Manages local accounts as data: define users, their groups, login shell, and SSH public key in one list and apply the same state everywhere.


The play is a single, self-contained play with the standard shape: a `vars:` block (every tunable with
a safe default), a `tasks:` block, and — where a service is touched — a `handlers:` block that restarts
or reloads the service only when a change actually occurred.

---

## Idempotency & safety

- **Set `managed_users_state=absent` carefully:** it removes the listed accounts.
- **Home dirs are created** but never deleted by this play.

- **Idempotent:** re-running makes no changes once the host is in the desired state.
- **Check-mode safe:** supports `--check`/`--diff` to preview changes.
- **Cross-distro:** package names and service units are selected per `ansible_os_family`.

---

## Integration

### ansible.cfg and inventory

The repository ships an `ansible.cfg` with sane defaults and an `inventory.example.ini`. Group your
hosts there, then target a group with `--limit` or `-e target_hosts=<group>`.

### group_vars layout

```
ansible/
├── inventory.ini
├── group_vars/
│   ├── all.yml          # values for every host
│   └── web.yml          # values for the 'web' group only
└── user-management/
    └── user-management.yml
```

### CI/CD (lint and check on every push)

```yaml
# .gitlab-ci.yml (excerpt)
ansible-verify:
  image: python:3-slim
  script:
    - pip install ansible-core ansible-lint yamllint
    - yamllint ansible/
    - ansible-lint ansible/user-management/user-management.yml
    - ansible-playbook -i ansible/inventory.ini ansible/user-management/user-management.yml --syntax-check
```

### ansible-pull (self-provisioning nodes)

```bash
# Each node pulls the repo and applies the playbook to itself, e.g. from cron.
ansible-pull -U https://github.com/YOUR_USER/linux-sysadmin-toolkit.git \
    ansible/user-management/user-management.yml
```

### Molecule (role/playbook testing)

Point a Molecule `converge.yml` at this playbook to test it in a throwaway container or VM before it
reaches production.

### AWX / Ansible Tower

Add the repository as a Project and create a Job Template whose playbook is
`ansible/user-management/user-management.yml`; expose the variables above as survey fields.

---

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `managed_users` | `(list)` | Users: name, groups, shell, ssh_key. |
| `managed_groups` | `[ops]` | Groups to create. |
| `managed_users_state` | `present` | present or absent for the listed users. |
| `target_hosts` | `all` | Host pattern the play targets. |

---

## Exit behavior

| Result | Meaning |
|---|---|
| `ok` / `changed=0` | Host already in the desired state (idempotent no-op). |
| `changed>0` | Configuration was applied; handlers ran as needed. |
| `failed` | A task failed; the play stops for that host. Re-run after fixing the cause. |

---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. |

---

## Author

**Filcu Alexandru**

---

## License

MIT
