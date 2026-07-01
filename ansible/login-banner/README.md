# login-banner

Set consistent /etc/issue, issue.net, motd and the SSH banner.

---

## Purpose

Presents a consistent authorized-use notice at every entry point (local TTY, pre-auth SSH, and MOTD) — a common requirement for security and legal compliance.

## What it does

- Writes the same banner to `/etc/issue`, `/etc/issue.net`, and `/etc/motd`.
- Enables the sshd `Banner` directive, validated by `sshd -t`.
- Restarts SSH only on change.

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
| `login_banner_text` | `(text)` | Banner body shown at login. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini login-banner.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini login-banner.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini login-banner.yml --limit web -e 'target_hosts=db'
```

---

## Idempotency & safety

- **Validated:** the sshd edit is checked with `sshd -t` before saving.
- **Cosmetic & safe:** only writes banner files and one sshd directive.

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
