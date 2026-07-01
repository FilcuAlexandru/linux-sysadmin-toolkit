<div align="center">

# Ansible SysAdmin Toolkit

### 25 idempotent, cross-distro Ansible playbooks that configure and harden Linux hosts

*One folder per task — readable, builtin-only, and safe to run twice.*

![Ansible](https://img.shields.io/badge/ansible--core-2.12%2B-EE0000?logo=ansible&logoColor=white)
![Playbooks](https://img.shields.io/badge/playbooks-25-success)
![Collections](https://img.shields.io/badge/collections-none_(builtin_only)-success)
![Lint](https://img.shields.io/badge/ansible--lint-production_profile-brightgreen)
![Mode](https://img.shields.io/badge/idempotent-%2F%2F%20--check%20safe-blue)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

The `ansible/` section is the **enforce-desired-state** half of the toolkit. Where the `bash/` and
`python/` sections observe and report, these playbooks *configure* a host: harden SSH, set up the
firewall, manage users, patch packages, lay out storage. Each describes the **state** a system should
be in, so running a playbook twice changes nothing the second time. Everything uses
**`ansible.builtin` modules only** — there are no collections to install — and works across
**Debian/Ubuntu, RHEL/Rocky/Alma, and SUSE/SLES** via `ansible_os_family` conditionals.

All 25 playbooks pass `ansible-lint` at the strict **production** profile, plus `yamllint` and
`ansible-playbook --syntax-check`.

---

## 1. Ansible in two minutes (for this section)

- **Playbook** — a single file that lists the tasks to run on a group of hosts. Each playbook here is
  one self-contained play.
- **Task** — one step (install a package, template a file). Each task calls a **module**
  (`package`, `copy`, `template`, `lineinfile`, `user`, `cron`, `service`, …).
- **Variable** — a value you can override without touching tasks. Every tunable has a safe default in
  the play's `vars:` block; override it with `-e` or in `group_vars/`.
- **Handler** — a task that only runs when something changed (for example, restart SSH after its
  config file is updated).
- **Idempotent / `--check`** — re-running makes no further changes; `--check --diff` previews what
  *would* change without touching the host.

```bash
ansible-playbook -i inventory.example.ini ssh-hardening/ssh-hardening.yml --check --diff
```

---

## 2. The playbooks

### Security hardening

| Folder | What it enforces |
|---|---|
| `ssh-hardening` | A hardened, `sshd -t`-validated OpenSSH server configuration. |
| `sysctl-hardening` | A kernel/network hardening sysctl profile. |
| `firewall-baseline` | A validated default-deny inbound nftables ruleset. |
| `auditd-setup` | auditd plus baseline rules for sensitive identity files. |
| `fail2ban-setup` | Fail2ban with an SSH brute-force jail policy. |
| `login-banner` | Consistent legal banners (issue, issue.net, motd, SSH). |
| `password-policy` | Password aging (login.defs) and pwquality complexity. |
| `disable-unused-services` | Stops and disables risky/unused services, if present. |

### Users & access

| Folder | What it enforces |
|---|---|
| `user-management` | Local users, groups, shells, and authorized keys (data-driven). |
| `sudoers-management` | `visudo`-validated drop-ins under `/etc/sudoers.d`. |
| `ssh-key-deployment` | Appends authorized SSH public keys to existing accounts. |

### Packages & updates

| Folder | What it enforces |
|---|---|
| `package-baseline` | A required-present / unwanted-absent package baseline. |
| `automatic-updates` | Unattended security updates (unattended-upgrades / dnf-automatic). |
| `repo-management` | APT / YUM repositories, per distro family. |

### Services & system configuration

| Folder | What it enforces |
|---|---|
| `ntp-time-sync` | chrony with a managed NTP server list. |
| `timezone-locale` | System timezone (idempotently) and default locale. |
| `journald-config` | journald storage, size cap, and retention. |
| `logrotate-config` | A logrotate policy for an application's logs. |
| `cron-jobs` | Scheduled cron jobs, managed declaratively. |
| `ca-certificates` | Internal CA certificates added to the system trust store. |

### Storage

| Folder | What it enforces |
|---|---|
| `lvm-volume` | A VG/LV, filesystem, and mount — guarded against data loss. |
| `fstab-mounts` | `/etc/fstab` entries (NFS/local) and their mount points. |
| `swap-configuration` | A swap file, created and persisted idempotently. |

### Networking & patching

| Folder | What it enforces |
|---|---|
| `hosts-dns-config` | Hostname, a managed `/etc/hosts` block, and optional DNS. |
| `system-update-reboot` | Full package patching; reboots only when required and permitted. |

---

## 3. Folder structure

Each playbook lives in its own folder with a dedicated README — the same layout as the `bash/` section:

```
ansible/
├── README.md                 this index
├── ansible.cfg               sane defaults for running the playbooks
├── inventory.example.ini     sample inventory — copy and edit
└── <task>/
    ├── <task>.yml            the playbook
    └── README.md             purpose, variables, usage, idempotency/safety
```

Each playbook is a single play with the standard shape: a `vars:` block (every tunable with a safe
default), a `tasks:` block, and — where a service is touched — a `handlers:` block that restarts or
reloads only on change.

---

## 4. Requirements

- **Control node:** `ansible-core` 2.12+ — no extra collections required (`ansible.builtin` only).
- **Managed nodes:** Debian/Ubuntu, RHEL/Rocky/AlmaLinux, or SUSE/SLES with Python 3.
- **Privilege:** the plays use `become: true`; run as a user that can escalate, or pass
  `--ask-become-pass`.

---

## 5. Usage

```bash
# Always preview first.
ansible-playbook -i inventory.example.ini ssh-hardening/ssh-hardening.yml --check --diff

# Apply to a host group.
ansible-playbook -i inventory.example.ini ssh-hardening/ssh-hardening.yml --limit web

# Override a variable at run time.
ansible-playbook -i inventory.example.ini ssh-hardening/ssh-hardening.yml \
  -e ssh_permit_root_login=no
```

Copy `inventory.example.ini` to your own inventory and edit the host groups first.

---

## 6. Idempotency & safety

- **Idempotent:** re-running changes nothing once the host is in the desired state.
- **Check-mode safe:** every playbook supports `--check`/`--diff`.
- **Guarded destructive steps:** storage playbooks never reformat or shrink existing data, and
  `system-update-reboot` only reboots when the OS reports it is required **and** `allow_reboot=true`.
- **Validated edits:** SSH config is checked with `sshd -t`, sudoers with `visudo -cf`, and the
  firewall ruleset with `nft -c` before being applied.

---

## 7. Quality checks

```bash
yamllint .
ansible-lint                                  # passes the 'production' profile
for f in */*.yml; do ansible-playbook --syntax-check "$f"; done
```

---

## Author

Filcu Alexandru

## License

MIT
