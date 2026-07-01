# ssh-hardening

Apply a hardened, validated OpenSSH server configuration.

---

## Purpose

Brings every host to a consistent, hardened SSH baseline: no password auth, limited root login, sane keepalive and auth-try limits. Each change is validated with `sshd -t` so a typo can never lock you out via a broken config.

## What it does

- Installs the OpenSSH server package (name resolved per distro).
- Sets hardened directives with `lineinfile`, validated by `sshd -t` before saving.
- Restarts SSH only on change, via a handler.

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
| `ssh_port` | `22` | SSH listen port. |
| `ssh_permit_root_login` | `prohibit-password` | PermitRootLogin value. |
| `ssh_password_authentication` | `"no"` | Allow password auth (keep keys-only). |
| `ssh_max_auth_tries` | `4` | MaxAuthTries before disconnect. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini ssh-hardening.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini ssh-hardening.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini ssh-hardening.yml --limit web -e 'ssh_permit_root_login=no'
```

---

## Idempotency & safety

- **Validated:** every edit runs `sshd -t`; an invalid config is rejected and the file is left unchanged.
- **Non-locking:** does not drop active sessions; the handler only restarts the service after a successful, validated change.

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
