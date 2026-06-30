<div align="center">

# Linux SysAdmin Toolkit

### Bash monitors, Python audits, and Ansible playbooks for everyday Linux administration

*One folder per task — readable, idempotent where it matters, and beginner-friendly.*

![Bash](https://img.shields.io/badge/Bash-monitoring_%26_audit-4EAA25?logo=gnubash&logoColor=white)
![Python](https://img.shields.io/badge/Python-stdlib_only-3776AB?logo=python&logoColor=white)
![Ansible](https://img.shields.io/badge/Ansible-production_profile-EE0000?logo=ansible&logoColor=white)
![Bash scripts](https://img.shields.io/badge/bash-40-success)
![Python scripts](https://img.shields.io/badge/python-40-success)
![Ansible playbooks](https://img.shields.io/badge/ansible-25-success)
![Lint](https://img.shields.io/badge/ansible--lint-passing-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

</div>

---

**Linux SysAdmin Toolkit** is a portable collection of administration tooling organised into three
sections. Two of them **observe** a system and alert when something is wrong; the third **enforces**
the state a system should be in. Everything is designed to run on any modern distribution —
**SLES, RHEL/Rocky/Alma, Ubuntu, and Debian** — without relying on distribution-specific behaviour
unless that behaviour is explicitly detected and handled.

The toolkit is organised so you can read **one folder per task** and understand exactly what a
sysadmin would otherwise do by hand.

```
bash/      40 self-contained monitoring & audit scripts
python/    40 standard-library audit scripts (JSON output)
ansible/   25 idempotent configuration & hardening playbooks
```

---

## 1. The three sections in two minutes

If you are new to this repository, here are the only ideas you need:

- **`bash/` — observe and alert.** Self-contained Bash scripts that check one thing (CPU, inodes,
  failed logins, RAID health…) and raise an alert when a threshold is crossed. They run from cron or
  a systemd timer and need nothing installed beyond Bash.
- **`python/` — observe and report.** The same idea in Python, using only the standard library. Each
  script prints a **JSON** result so it can feed a monitoring pipeline, and returns a clear exit code.
- **`ansible/` — enforce desired state.** Idempotent playbooks that *configure* a system: harden SSH,
  set up the firewall, manage users, patch packages, lay out storage. Running a playbook twice changes
  nothing the second time, because each task describes the desired **state**, not commands.

A few terms used throughout:

- **Dry run** — every Bash and Python script supports `--dry-run`, and every playbook supports
  `--check`: preview what *would* happen without changing anything.
- **Idempotent** — re-running makes no further changes once the system is already in the desired state.
- **Configuration block / variables** — you change behaviour by editing values, never the logic:
  Bash and Python keep their settings at the top of the file (above a clear marker); Ansible exposes
  every tunable as a variable with a safe default.

---

## 2. Project layout

```
linux-sysadmin-toolkit/
├── README.md                 this file
├── LICENSE
├── bash/
│   ├── README.md             index of all 40 scripts
│   └── <task>/               one folder per script
│       ├── <task>.sh
│       └── README.md
├── python/
│   ├── README.md             index of all 40 scripts
│   └── NN-<task>/            numbered, one folder per script
│       ├── <task>.py
│       └── README-<task>.md
└── ansible/
    ├── README.md             index of all 25 playbooks
    ├── ansible.cfg           sane defaults for running the playbooks
    ├── inventory.example.ini sample inventory — copy and edit
    └── NN-<task>/            numbered, one folder per playbook
        ├── <task>.yml
        └── README.md
```

Every item lives in its own folder with a dedicated README describing its purpose, usage,
dependencies, and exit/behaviour details.

---

## 3. What lives in each section

| Section | Count | Role | Output | Runs from |
|---|---|---|---|---|
| `bash/` | 40 | Observe & alert | Console + email + log | cron / systemd timer |
| `python/` | 40 | Observe & report | JSON on stdout | cron / systemd timer / pipeline |
| `ansible/` | 25 | Enforce desired state | Changed/ok task report | Ansible control node |

The `bash/` and `python/` sections cover overlapping topics in two languages, so you can pick whichever
suits a given host. The `ansible/` section is the one that *changes* configuration.

---

## 4. What each section contains

**`bash/` — 40 monitoring & audit scripts.** Every script shares the same engine: configuration at the
top above a `no changes needed past this line` marker, `--dry-run` / `--maintenance` / `--version` /
`--help`, instance locking with `flock`, rate-limited email alerts, status-aware alerting with recovery,
and self-rotating logs. Topics include CPU, memory, swap, disk and inode usage, load, failed logins,
SSH config, firewall status, RAID and SMART health, NTP sync, open files, conntrack, journal usage,
reboot-required detection, and more. See [`bash/README.md`](bash/README.md) for the full list.

**`python/` — 40 audit scripts.** Standard library only (Python 3.6+); each prints a JSON document and
returns `0` (OK), `1` (ALERT), or `2` (ERROR). They share the same operational features as the Bash
scripts (locking, logging, maintenance mode, email rate-limiting) and add privilege reporting in
`--dry-run`. Topics include a full system monitor, disk-trend and capacity forecasting, process and
memory-leak detection, user/SSH-key/sudoers/SUID audits, TLS-certificate scanning, package-update and
sysctl audits, and file-integrity baselining. See [`python/README.md`](python/README.md).

**`ansible/` — 25 configuration & hardening playbooks.** Each teaches a standard module or technique:

- **ssh-hardening** — `lineinfile` with `validate: sshd -t`, plus a **handler** that restarts SSH only
  on change.
- **sysctl-hardening / journald-config / password-policy** — render managed config from variables.
- **firewall-baseline** — a validated, default-deny `nftables` ruleset built from an allow-list.
- **users / sudoers / ssh-key-deployment** — `user`, `group`, and `copy` with `validate: visudo -cf`.
- **package-baseline / automatic-updates / repo-management** — cross-distro package management with the
  generic `package` module and family-specific repo modules.
- **ntp-time-sync / timezone-locale / ca-certificates** — service configuration with per-distro paths.
- **lvm-volume / fstab-mounts / swap-configuration** — storage, with destructive steps guarded so
  existing data is never reformatted.
- **system-update-reboot** — patch packages and reboot *only* when required and explicitly permitted.

Everything uses `ansible.builtin` modules only — no extra collections to install. See
[`ansible/README.md`](ansible/README.md).

---

## 5. Requirements

- **`bash/`** — Bash 4.x+ and a Linux `/proc` (and where noted `/sys`) filesystem. Optional tools
  (`mail`, `flock`, `find`, and a few task-specific ones) degrade gracefully when missing.
- **`python/`** — Python 3.6+ (standard library only; no `pip install`).
- **`ansible/`** — `ansible-core` 2.12+ on the control node. Managed hosts need only Python 3.
  `yamllint` and `ansible-lint` are optional, for validation.

---

## 6. Run it

```bash
# Bash — preview first, then schedule from cron/systemd.
./bash/cpu-usage-monitor/cpu-usage-monitor.sh --dry-run
./bash/inode-usage-monitor/inode-usage-monitor.sh

# Python — JSON output, exit code signals OK/ALERT/ERROR.
python3 python/01-system-monitor/system-monitor.py
python3 python/39-file-integrity-monitor/file-integrity-monitor.py --dry-run

# Ansible — always preview with --check first, then apply.
ansible-playbook -i ansible/inventory.example.ini \
  ansible/01-ssh-hardening/ssh-hardening.yml --check --diff
ansible-playbook -i ansible/inventory.example.ini \
  ansible/01-ssh-hardening/ssh-hardening.yml --limit web
```

---

## 7. Change things without editing logic

Everything configurable is a value, not code:

- **Bash** — edit the variables at the top of the script, above the
  `no changes needed past this line` marker (for example `THRESHOLD`, `ALERT_EMAIL`).
- **Python** — edit the configuration constants near the top of the file
  (for example `INODE_THRESHOLD`, `MAX_OFFSET_MS`).
- **Ansible** — override a variable on the command line with `-e`, or set it in
  `group_vars/` / inventory (for example `-e ssh_permit_root_login=no`).

Then re-run the script or `ansible-playbook`.

---

## 8. How the sections fit together

`bash/` and `python/` answer *"what is the current state, and is anything wrong?"* — they are read-only
by design and alert on problems. `ansible/` answers *"bring the host to the state it should be in"* —
it configures and hardens, and can be re-run safely. A common workflow is to enforce a baseline with a
playbook, then keep watch with the matching monitor.

---

## 9. Quality checks

```bash
# Bash — syntax check every script.
for f in bash/*/*.sh; do bash -n "$f"; done

# Python — compile every script (standard library only).
python3 -m py_compile python/*/*.py

# Ansible — lint and syntax-check (passes the 'production' profile).
cd ansible
yamllint .
ansible-lint
for f in */*.yml; do ansible-playbook --syntax-check "$f"; done
```

---

## License

Released under the MIT License. See [LICENSE](LICENSE).
