# 21-lvm-volume

Create a VG/LV, make a filesystem, and mount it (guarded).

---

## Purpose

Provisions block storage end to end — volume group, logical volume, filesystem, and mount — with explicit safeguards so it never destroys or shrinks existing data.

## What it does

- Creates PV/VG/LV with guarded `pvcreate`/`vgcreate`/`lvcreate` (only when absent).
- Runs `mkfs` only on a newly created volume, so existing data is never reformatted.
- Adds the fstab entry and mounts via a handler. Uses `ansible.builtin` only.

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
| `lvm_pvs` | `/dev/sdb` | Physical volume device(s) for the VG. |
| `lvm_lv_size` | `10g` | Logical volume size. |
| `lvm_mount_point` | `/data` | Where to mount the filesystem. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini lvm-volume.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini lvm-volume.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini lvm-volume.yml --limit web -e 'lvm_mount_point=/srv/data'
```

---

## Idempotency & safety

- **Destructive-by-nature, guarded:** every step runs only when the PV/VG/LV does not already exist, and `mkfs` runs only on a freshly created volume — existing data is never reformatted or shrunk.
- **Verify the device:** double-check `lvm_pvs` points at the intended disk. Always run `--check` first and never target a disk with live data.

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
