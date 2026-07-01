# system-update-reboot

Apply all package updates and reboot only when needed and allowed.

---

## Features

- Updates packages via `apt`/`dnf`/`zypper` based on `ansible_os_family`.
- Detects a required reboot (`/var/run/reboot-required` or `needs-restarting -r`).
- Reboots only when `allow_reboot=true` and a reboot is actually needed.
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
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml --check
```

---

## Variables

All variables have safe defaults and can be overridden with `-e` on the command line, or in
`group_vars/` / `host_vars/`.

| Variable | Default | Description |
|---|---|---|
| `allow_reboot` | `false` | Must be true to permit an automatic reboot. |
| `reboot_timeout` | `600` | Seconds to wait for the host to return. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

### Overriding variables

```bash
# Inline, for a single run.
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml -e 'allow_reboot=true'
```

```yaml
# Persistently, in group_vars/all.yml (applies to every host):
allow_reboot: true
```

---

## Usage

```bash
# 1) Always preview first — shows exactly what would change, changes nothing.
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml --check --diff

# 2) Apply to every host in the inventory.
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml

# 3) Limit to a host group.
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml --limit web

# 4) Prompt for the sudo password when the login user needs it.
ansible-playbook -i inventory.ini system-update-reboot/system-update-reboot.yml --ask-become-pass
```

A typical `PLAY RECAP` after a first apply:

```
PLAY RECAP *********************************************************************
web01  : ok=4  changed=2  unreachable=0  failed=0  skipped=0
```

Re-running immediately afterwards shows `changed=0` — proof the play is idempotent.

---

## How it works

Performs full system patching per distro family and reboots only when the OS reports a reboot is required and the operator has explicitly permitted it.


The play is a single, self-contained play with the standard shape: a `vars:` block (every tunable with
a safe default), a `tasks:` block, and — where a service is touched — a `handlers:` block that restarts
or reloads the service only when a change actually occurred.

---

## Idempotency & safety

- **Reboot is opt-in:** nothing reboots unless `allow_reboot=true` AND the OS signals a reboot is required.
- **Builtin-only:** SUSE patching uses `zypper` via the command module so no extra collections are required.
- **Run in maintenance windows** and use `--check` to preview the update scope.

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
└── system-update-reboot/
    └── system-update-reboot.yml
```

### CI/CD (lint and check on every push)

```yaml
# .gitlab-ci.yml (excerpt)
ansible-verify:
  image: python:3-slim
  script:
    - pip install ansible-core ansible-lint yamllint
    - yamllint ansible/
    - ansible-lint ansible/system-update-reboot/system-update-reboot.yml
    - ansible-playbook -i ansible/inventory.ini ansible/system-update-reboot/system-update-reboot.yml --syntax-check
```

### ansible-pull (self-provisioning nodes)

```bash
# Each node pulls the repo and applies the playbook to itself, e.g. from cron.
ansible-pull -U https://github.com/YOUR_USER/linux-sysadmin-toolkit.git \
    ansible/system-update-reboot/system-update-reboot.yml
```

### Molecule (role/playbook testing)

Point a Molecule `converge.yml` at this playbook to test it in a throwaway container or VM before it
reaches production.

### AWX / Ansible Tower

Add the repository as a Project and create a Job Template whose playbook is
`ansible/system-update-reboot/system-update-reboot.yml`; expose the variables above as survey fields.

---

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `allow_reboot` | `false` | Must be true to permit an automatic reboot. |
| `reboot_timeout` | `600` | Seconds to wait for the host to return. |
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
