# 03-firewall-baseline

Install nftables and enforce a default-deny inbound ruleset.

---

## Purpose

Establishes a portable, default-deny inbound firewall using nftables (available on Debian/Ubuntu, RHEL family, and SUSE), with an explicit allow-list of TCP/UDP ports.

## What it does

- Installs and enables the `nftables` service.
- Renders a default-deny ruleset from `firewall_allowed_tcp_ports`/`_udp_ports`.
- Validates the ruleset with `nft -c` before applying; reloads on change.

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
| `firewall_allowed_tcp_ports` | `[22]` | Inbound TCP ports to allow. |
| `firewall_allowed_udp_ports` | `[]` | Inbound UDP ports to allow. |
| `nftables_conf_path` | `/etc/nftables.conf` | Ruleset file path. |
| `target_hosts` | `all` | Host pattern the play targets. Override with `-e target_hosts=web`. |

---

## Usage

```bash
# Dry run (no changes) — always check first.
ansible-playbook -i inventory.example.ini firewall-baseline.yml --check --diff

# Apply.
ansible-playbook -i inventory.example.ini firewall-baseline.yml

# Limit to a subset and override a variable.
ansible-playbook -i inventory.example.ini firewall-baseline.yml --limit web -e 'firewall_allowed_tcp_ports=[22,80,443]'
```

---

## Idempotency & safety

- **Validated:** `nft -c -f` checks the ruleset before it is committed.
- **Keep SSH open:** port 22 is allowed by default — review the allow-list before applying to avoid locking yourself out. Always run with `--check --diff` first.

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
