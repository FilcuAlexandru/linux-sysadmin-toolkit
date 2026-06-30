# 20-ca-certificates

Deploy internal CA certificates and update the system trust store.

---

## Purpose

Distributes internal/enterprise CA certificates to the system trust store so hosts trust internal TLS services, using the correct anchor directory and update command per distro.

## What it does

- Selects the trust-anchor directory and update command per `ansible_os_family`.
- Copies each provided CA cert and updates the trust store on change.
- Cert list provided via `ca_certificates` (paths on the control node).

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
| `ca_certificates` | `[]` | List of CA cert files (.crt/.pem) to install. |
| `ca_trust_dir` | `(auto)` | Trust-anchor directory, per distro. |
| `ca_update_command` | `(auto)` | Trust-store update command, per distro. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini ca-certificates.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini ca-certificates.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini ca-certificates.yml --limit web -e 'target_hosts=all'
```

---

## Idempotency & safety

- **No-op by default:** `ca_certificates` is empty until you provide certs.
- **Trust impact:** only add CAs you control; installing a CA makes the host trust anything it signs.

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
