# installed-packages.sh

Lightweight Bash script that lists all installed packages and their versions. Auto-detects the package manager and works on Debian/Ubuntu, RHEL/Fedora/SLES, Arch Linux, openSUSE, and Alpine — no configuration needed to switch distributions.

Unlike the monitoring scripts in this collection, this script is **read-only inventory** — it has no alerting, no email, and no status tracking.

---

## Features

- **Auto-detection** — probes available package managers in priority order and uses the first one found: `dpkg` → `rpm` → `pacman` → `zypper` → `apk`.
- **Aligned table output** — two-column `PACKAGE / VERSION` table aligned with `awk`, no dependency on the `column` command.
- **Plain format** — optional `name=version` output per line, suitable for piping to `grep`, `sort`, `diff`, or other tools.
- **Optional log file** — save output to a file on every run, with automatic rotation and retention-based pruning.
- **Prerequisites check** — `--dry-run` shows which package managers are available and the active configuration.
- **Distro-agnostic** — works across all major Linux distributions without any configuration change.
- **Self-contained configuration** — all settings live inside the script.

---

## Requirements

- **Bash 4.x+**
- **At least one supported package manager** — see the table below.

Optional:

- **`find`** — for log rotation (`findutils`).

### Supported package managers

| Distribution | Tool | Package |
|---|---|---|
| Debian / Ubuntu | `dpkg-query` | pre-installed |
| RHEL / CentOS / Fedora | `rpm` | pre-installed |
| SLES / openSUSE | `zypper` or `rpm` | pre-installed |
| Arch Linux / Manjaro | `pacman` | pre-installed |
| Alpine Linux | `apk` | pre-installed |

---

## Installation

### From Git (recommended)

```bash
# Clone the entire repository.
git clone https://github.com/YOUR_USER/linux-monitor-scripts.git
cd linux-monitor-scripts

# Or fetch just this script with curl.
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/installed-packages.sh \
     -o /opt/scripts/installed-packages.sh

# Or with wget.
wget -q https://raw.githubusercontent.com/YOUR_USER/linux-monitor-scripts/main/installed-packages.sh \
     -O /opt/scripts/installed-packages.sh
```

### Manual copy

```bash
cp installed-packages.sh /opt/scripts/installed-packages.sh
chmod +x /opt/scripts/installed-packages.sh
```

### Verify

```bash
/opt/scripts/installed-packages.sh --version
/opt/scripts/installed-packages.sh --dry-run
```

---

## Configuration

All configuration is done by editing the variables at the top of the script. No changes are needed below the separator line.

### Output format

```bash
OUTPUT_FORMAT="table"
SHOW_TOTAL=1
```

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_FORMAT` | `"table"` | `"table"` for aligned columns, `"plain"` for `name=version` per line. |
| `SHOW_TOTAL` | `1` | Set to `0` to suppress the total package count line. |

#### Table format (default)

```
PACKAGE                    VERSION
adduser                    3.137ubuntu1
apt                        2.8.3
bash                       5.2.37-1
...

Total installed packages: 866 (via dpkg)
```

#### Plain format

```bash
OUTPUT_FORMAT="plain"
```

```
adduser=3.137ubuntu1
apt=2.8.3
bash=5.2.37-1
```

Useful for scripting:

```bash
# Check if nginx is installed and get its version.
./installed-packages.sh | grep '^nginx='

# Compare packages between two snapshots.
./installed-packages.sh > before.txt
# ... (make changes) ...
./installed-packages.sh > after.txt
diff before.txt after.txt

# Count packages matching a pattern.
./installed-packages.sh | grep '^python' | wc -l
```

### Log file

```bash
LOG_FILE=""
LOG_RETENTION_DAYS="14"
```

| Variable | Default | Description |
|---|---|---|
| `LOG_FILE` | `""` *(disabled)* | Path to save the output on each run. Empty = disabled. |
| `LOG_RETENTION_DAYS` | `14` | Rotate and prune log files older than this. `0` = keep forever. |

When `LOG_FILE` is set, the output is written to the file **and** printed to stdout (via `tee`). The log file includes a header line with the timestamp, package manager used, and package count:

```
# installed-packages.sh — 2026-06-20 08:00:01 — dpkg — 866 packages
adduser=3.137ubuntu1
apt=2.8.3
...
```

Example:

```bash
LOG_FILE="${SCRIPT_DIR}/logs/installed-packages.log"
LOG_RETENTION_DAYS="30"
```

---

## Usage

```
Usage: installed-packages.sh [--dry-run] [--version] [--help]

Options:
  --dry-run   Check prerequisites and show configuration without listing packages
  --version   Show version and exit
  --help      Show this help and exit
```

### Basic run

```bash
./installed-packages.sh
```

```
PACKAGE                    VERSION
adduser                    3.137ubuntu1
apt                        2.8.3
bash                       5.2.37-1
coreutils                  8.32-4.1ubuntu1
...

Total installed packages: 866 (via dpkg)
```

### Dry-run

```bash
./installed-packages.sh --dry-run
```

```
Package managers (first available will be used):
  dpkg-query                   OK
  rpm                          MISSING
  pacman                       MISSING
  zypper                       MISSING
  apk                          MISSING

Optional tools:
  find                         OK

Configuration:
  Output format:               table
  Show total:                  yes
  Log file:                    DISABLED
```

---

## How it works

### Package manager detection

The script probes each supported manager in order and uses the first one found:

```
dpkg-query  →  rpm  →  pacman  →  zypper  →  apk
```

On a system with both `dpkg-query` and `rpm` (possible on some hybrid environments), `dpkg-query` takes priority. The detected manager is shown in the total line: `Total installed packages: 866 (via dpkg)`.

### Per-manager query

| Manager | Command used | Notes |
|---|---|---|
| `dpkg` | `dpkg-query -W -f='${binary:Package}\t${Version}\n'` | Debian/Ubuntu native format. |
| `rpm` | `rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\n'` | RHEL, Fedora, SLES. |
| `pacman` | `pacman -Q` | Arch Linux, Manjaro. |
| `zypper` | `zypper packages --installed-only` | openSUSE (parses pipe-delimited output). |
| `apk` | `apk info -v` | Alpine Linux. |

All output is normalized to `name<TAB>version` before sorting and formatting.

### Output alignment

Table alignment is done entirely in `awk` — no dependency on the `column` command (which is missing on many minimal and container systems). `awk` reads all lines first, tracks the longest package name, then reprints everything with consistent padding.

---

---

## Logging

### Execution log

When `LOG_FILE` is set, the script writes output to the file **and** prints it to stdout (via `tee`). The log file includes a header line with the timestamp, package manager, and count:

```
# installed-packages.sh — 2026-06-20 08:00:01 — dpkg — 866 packages
adduser=3.137ubuntu1
apt=2.8.3
bash=5.2.37-1
...
```

### Log rotation

At every run, the script checks `LOG_FILE`. If older than `LOG_RETENTION_DAYS`, it is renamed with a timestamp suffix and a fresh log is started. Archived copies older than the retention window are deleted.

Self-contained — no dependency on `logrotate`. If `find` is unavailable, rotation is silently skipped.

| `LOG_RETENTION_DAYS` | Behaviour |
|---|---|
| `14` (default) | Keep two weeks of logs. |
| `7` | Keep one week. |
| `90` | Keep three months. |
| `0` | No rotation; logs grow indefinitely. |


---

## Integration

### Container usage (Docker)

Pass a custom output directory when running inside a container:

```bash
docker run --rm \
  -v /host/output:/output \
  alpine/bash \
  bash /scripts/installed-packages.sh
```

Set `OUTPUT_DIR` to the mounted path so collected files are accessible from the host.


### Cron (scheduled snapshot)

```cron
0 6 * * * /opt/scripts/installed-packages.sh >/dev/null 2>&1
```

With `LOG_FILE` set, saves a snapshot daily. The log header makes each run identifiable.

### Change detection

```bash
# Before a deployment.
./installed-packages.sh > /tmp/before.txt

# After the deployment.
./installed-packages.sh > /tmp/after.txt

# Show what changed.
diff /tmp/before.txt /tmp/after.txt
```

### Cross-distribution inventory

The same script works on all supported distributions without modification:

```bash
# On Debian/Ubuntu — uses dpkg.
ssh app-server-01 /opt/scripts/installed-packages.sh > app01-packages.txt

# On RHEL — uses rpm.
ssh db-server-01 /opt/scripts/installed-packages.sh > db01-packages.txt

# Compare.
diff app01-packages.txt db01-packages.txt
```

## Use cases

### Manual audit

Quick inventory of what is installed on a server:

```bash
./installed-packages.sh
```

### Scheduled snapshot

Save a snapshot daily for audit trails or change tracking:

```bash
LOG_FILE="/var/log/package-snapshots/installed-packages.log"
LOG_RETENTION_DAYS="90"
```

```cron
0 6 * * * /opt/scripts/installed-packages.sh >/dev/null 2>&1
```

### Change detection between snapshots

```bash
# Before a deployment.
./installed-packages.sh > /tmp/before.txt

# After the deployment.
./installed-packages.sh > /tmp/after.txt

# Show what changed.
diff /tmp/before.txt /tmp/after.txt
```

### Find a specific package

```bash
# Is nginx installed?
./installed-packages.sh | grep '^nginx'

# All Python packages.
./installed-packages.sh | grep '^python'

# Exact version of bash.
./installed-packages.sh | grep '^bash='
```

### Cross-distribution inventory

The same script works on all supported distributions without modification. Run it in a mixed-OS environment (Debian app servers + RHEL database servers) and get consistent output format everywhere:

```bash
# On Debian/Ubuntu — uses dpkg.
ssh app-server-01 /opt/scripts/installed-packages.sh > app01-packages.txt

# On RHEL — uses rpm.
ssh db-server-01 /opt/scripts/installed-packages.sh > db01-packages.txt

# Compare.
diff app01-packages.txt db01-packages.txt
```

---

## Configuration reference

| Variable | Default | Description |
|---|---|---|
| `OUTPUT_FORMAT` | `"table"` | `"table"` or `"plain"`. |
| `SHOW_TOTAL` | `1` | Set to `0` to suppress the total count. |
| `LOG_FILE` | `""` *(disabled)* | Path to save output on each run. |
| `LOG_RETENTION_DAYS` | `14` | Days to keep log files. `0` = keep forever. |

---

## CLI reference

| Option | Description |
|---|---|
| `--dry-run` | Show available package managers and active configuration without listing packages. |
| `--version` | Print version and exit. |
| `--help` | Print usage information and exit. |

---

## Version history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-06 | Initial release. Multi-distro support added. |

---

## Author

**Filcu Alexandru**

---

## License

This script is provided as-is for personal and professional use.