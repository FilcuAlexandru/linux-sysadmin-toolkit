# 22-fstab-mounts

Declaratively manage /etc/fstab entries and mount them.

---

## Purpose

Manages persistent mounts (NFS, local, bind) as data in `/etc/fstab`, keeping entries consistent and ensuring their mount points exist.

## What it does

- Creates mount-point directories for present entries.
- Adds/updates/removes fstab lines keyed by mount path.
- Runs `mount -a` via a handler when fstab changes.

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
| `fstab_mounts` | `(list)` | Each: src, path, fstype, opts, state. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini fstab-mounts.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini fstab-mounts.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini fstab-mounts.yml --limit web -e 'target_hosts=app'
```

---

## Idempotency & safety

- **`mount -a` only mounts** currently-unmounted present entries; it does not unmount.
- **Removing an entry** (`state: absent`) edits fstab but does not unmount a live filesystem; unmount manually if needed.

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
