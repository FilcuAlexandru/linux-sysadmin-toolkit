# 24-hosts-dns-config

Set the hostname and manage /etc/hosts and resolver entries.

---

## Purpose

Centralizes host identity and name resolution: sets the hostname, manages a clearly marked block of `/etc/hosts` entries, and (optionally) the DNS resolvers.

## What it does

- Sets the hostname with the builtin `hostname` module when provided.
- Manages `/etc/hosts` entries inside a marked block (no clobbering other lines).
- Optionally writes `resolv.conf` nameservers (off by default).

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
| `system_hostname` | `""` | Hostname to set (empty = leave unchanged). |
| `hosts_entries` | `(list)` | Lines managed inside the /etc/hosts block. |
| `manage_resolv_conf` | `false` | Whether to write resolv.conf. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini hosts-dns-config.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini hosts-dns-config.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini hosts-dns-config.yml --limit web -e 'system_hostname=web01'
```

---

## Idempotency & safety

- **resolv.conf is opt-in:** disabled by default because `systemd-resolved`/NetworkManager often own it; enabling it on such hosts can be overwritten.
- **Scoped hosts block:** only the marked block is managed; the rest of `/etc/hosts` is left alone.

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
