# lvm-volume

Create a VG/LV, make a filesystem, and mount it (guarded).

---

## Features

- Creates PV/VG/LV with guarded `pvcreate`/`vgcreate`/`lvcreate` (only when absent).
- Runs `mkfs` only on a newly created volume, so existing data is never reformatted.
- Adds the fstab entry and mounts via a handler. Uses `ansible.builtin` only.
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
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml --check
```

---

## Variables

All variables have safe defaults and can be overridden with `-e` on the command line, or in
`group_vars/` / `host_vars/`.

| Variable | Default | Description |
|---|---|---|
| `lvm_pvs` | `/dev/sdb` | Physical volume device(s) for the VG. |
| `lvm_lv_size` | `10g` | Logical volume size. |
| `lvm_mount_point` | `/data` | Where to mount the filesystem. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

### Overriding variables

```bash
# Inline, for a single run.
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml -e 'lvm_mount_point=/srv/data'
```

```yaml
# Persistently, in group_vars/all.yml (applies to every host):
lvm_mount_point: /srv/data
```

---

## Usage

```bash
# 1) Always preview first — shows exactly what would change, changes nothing.
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml --check --diff

# 2) Apply to every host in the inventory.
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml

# 3) Limit to a host group.
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml --limit web

# 4) Prompt for the sudo password when the login user needs it.
ansible-playbook -i inventory.ini lvm-volume/lvm-volume.yml --ask-become-pass
```

A typical `PLAY RECAP` after a first apply:

```
PLAY RECAP *********************************************************************
web01  : ok=4  changed=2  unreachable=0  failed=0  skipped=0
```

Re-running immediately afterwards shows `changed=0` — proof the play is idempotent.

---

## How it works

Provisions block storage end to end — volume group, logical volume, filesystem, and mount — with explicit safeguards so it never destroys or shrinks existing data.


A **handler** restarts or reloads the affected service only when a task reports a change, so unrelated runs never bounce the service.

The play is a single, self-contained play with the standard shape: a `vars:` block (every tunable with
a safe default), a `tasks:` block, and — where a service is touched — a `handlers:` block that restarts
or reloads the service only when a change actually occurred.

---

## Idempotency & safety

- **Destructive-by-nature, guarded:** every step runs only when the PV/VG/LV does not already exist, and `mkfs` runs only on a freshly created volume — existing data is never reformatted or shrunk.
- **Verify the device:** double-check `lvm_pvs` points at the intended disk. Always run `--check` first and never target a disk with live data.

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
└── lvm-volume/
    └── lvm-volume.yml
```

### CI/CD (lint and check on every push)

```yaml
# .gitlab-ci.yml (excerpt)
ansible-verify:
  image: python:3-slim
  script:
    - pip install ansible-core ansible-lint yamllint
    - yamllint ansible/
    - ansible-lint ansible/lvm-volume/lvm-volume.yml
    - ansible-playbook -i ansible/inventory.ini ansible/lvm-volume/lvm-volume.yml --syntax-check
```

### ansible-pull (self-provisioning nodes)

```bash
# Each node pulls the repo and applies the playbook to itself, e.g. from cron.
ansible-pull -U https://github.com/YOUR_USER/linux-sysadmin-toolkit.git \
    ansible/lvm-volume/lvm-volume.yml
```

### Molecule (role/playbook testing)

Point a Molecule `converge.yml` at this playbook to test it in a throwaway container or VM before it
reaches production.

### AWX / Ansible Tower

Add the repository as a Project and create a Job Template whose playbook is
`ansible/lvm-volume/lvm-volume.yml`; expose the variables above as survey fields.

---

## Variables reference

| Variable | Default | Description |
|---|---|---|
| `lvm_pvs` | `/dev/sdb` | Physical volume device(s) for the VG. |
| `lvm_lv_size` | `10g` | Logical volume size. |
| `lvm_mount_point` | `/data` | Where to mount the filesystem. |
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
