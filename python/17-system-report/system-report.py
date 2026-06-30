#!/usr/bin/env python3

###############################################################################
# system-report.py                                                            #
# Generates a comprehensive daily system report by collecting CPU/memory/disk #
# inline and optionally loading cached JSON from other toolkit scripts.       #
# Aggregates user risk, failed logins, and disk alerts into a single          #
# daily JSON report with a summary section.                                   #
# Author: Filcu Alexandru                                                     #
###############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Optional: paths to cached JSON output files from other toolkit scripts.
# Leave empty to collect inline.
SYSTEM_MONITOR_OUTPUT = ""
USER_AUDIT_OUTPUT     = ""
PORTS_AUDIT_OUTPUT    = ""
FAILED_LOGIN_OUTPUT   = ""

# Inline collection thresholds
CPU_THRESHOLD    = 85.0
MEMORY_THRESHOLD = 90.0
DISK_THRESHOLD   = 90.0

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "system-report.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "system-report.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "system-report.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "system-report.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "system-report"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "system-report-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "system-report-execution.log")
_start_time    = time.time()
_lock_fd: Optional[object] = None

log = logging.getLogger(SCRIPT_NAME)


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def setup_logging() -> None:
    fmt = "%(asctime)s %(levelname)-8s %(message)s"
    log.setLevel(logging.DEBUG)
    for path, level in ((_EXECUTION_LOG, logging.INFO), (_ERROR_LOG, logging.WARNING)):
        try:
            fh = logging.FileHandler(path)
            fh.setLevel(level)
            fh.setFormatter(logging.Formatter(fmt, "%Y-%m-%d %H:%M:%S"))
            log.addHandler(fh)
        except OSError:
            pass
    sh = logging.StreamHandler(sys.stderr)
    sh.setLevel(logging.WARNING)
    sh.setFormatter(logging.Formatter(fmt, "%Y-%m-%d %H:%M:%S"))
    log.addHandler(sh)


def rotate_logs() -> None:
    if LOG_RETENTION_DAYS <= 0:
        return
    cutoff = datetime.datetime.now() - datetime.timedelta(days=LOG_RETENTION_DAYS)
    for fname in os.listdir(SCRIPT_DIR):
        if not fname.endswith(".log"):
            continue
        fpath = os.path.join(SCRIPT_DIR, fname)
        try:
            if datetime.datetime.fromtimestamp(os.path.getmtime(fpath)) < cutoff:
                os.remove(fpath)
        except OSError:
            pass


def resolve_hostname() -> str:
    return HOSTNAME_LABEL if HOSTNAME_LABEL else socket.gethostname()


def acquire_lock() -> Optional[object]:
    try:
        fd = open(LOCK_FILE, "w")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (IOError, OSError):
        return None


def release_lock(fd: object) -> None:
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()
        os.remove(LOCK_FILE)
    except OSError:
        pass


def should_send_email() -> bool:
    try:
        with open(STATE_FILE) as f:
            return (time.time() - float(f.read().strip())) >= EMAIL_INTERVAL
    except Exception:
        return True


def mark_email_sent() -> None:
    try:
        with open(STATE_FILE, "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def last_email_age() -> str:
    try:
        with open(STATE_FILE) as f:
            return f"{int(time.time() - float(f.read().strip()))}s ago"
    except Exception:
        return "never"


def get_status() -> str:
    try:
        with open(STATUS_FILE) as f:
            s = f.read().strip()
        return s if s in ("OK", "ALERT") else "OK"
    except Exception:
        return "OK"


def set_status(status: str) -> None:
    try:
        with open(STATUS_FILE, "w") as f:
            f.write(status)
    except OSError:
        pass


def send_recovery_mail(body: str = "") -> None:
    if not ALERT_EMAIL:
        return
    _send_mail(
        f"{SCRIPT_NAME} recovery on {resolve_hostname()}",
        body or f"All checks passed on {resolve_hostname()}.",
    )
    log.warning("RECOVERY EMAIL sent to %s", ALERT_EMAIL)


def is_maintenance() -> bool:
    return os.path.exists(MAINTENANCE_FILE)


def toggle_maintenance() -> None:
    if os.path.exists(MAINTENANCE_FILE):
        os.remove(MAINTENANCE_FILE)
        print(json.dumps({"maintenance": "disabled"}))
    else:
        open(MAINTENANCE_FILE, "w").close()
        print(json.dumps({"maintenance": "enabled"}))
    sys.exit(0)


def _send_mail(subject: str, body: str) -> None:
    if not ALERT_EMAIL:
        return
    try:
        subprocess.run(
            ["mail", "-s", subject] + ALERT_EMAIL.split(),
            input=body.encode(), timeout=30, check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def alert(detail: str) -> None:
    if is_maintenance():
        return
    log.warning("ALERT %s", detail)
    if ALERT_EMAIL and should_send_email():
        _send_mail(f"Alert: {SCRIPT_NAME} on {resolve_hostname()}", detail)
        mark_email_sent()
        log.warning("EMAIL sent to %s", ALERT_EMAIL)



def _load_json(path: str) -> Optional[Dict]:
    if path and os.path.isfile(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            pass
    return None


def collect_system_metrics() -> Dict:
    m: Dict[str, int] = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                parts = line.split()
                if len(parts) >= 2:
                    m[parts[0].rstrip(":")] = int(parts[1])
    except OSError:
        pass
    try:
        with open("/proc/stat") as f:
            parts = f.readline().split()
        total = sum(int(x) for x in parts[1:])
        idle  = int(parts[4]) + int(parts[5])
        time.sleep(0.2)
        with open("/proc/stat") as f:
            parts2 = f.readline().split()
        total2 = sum(int(x) for x in parts2[1:])
        idle2  = int(parts2[4]) + int(parts2[5])
        dt     = total2 - total
        cpu_pct = round((1.0 - (idle2 - idle) / dt) * 100, 1) if dt else 0.0
    except Exception:
        cpu_pct = 0.0
    tot_kb  = m.get("MemTotal", 0)
    avail_kb = m.get("MemAvailable", 0)
    used_kb  = tot_kb - avail_kb
    disks_over = []
    try:
        out = subprocess.run(["df", "-P", "--block-size=1"],
                             capture_output=True, text=True, timeout=15).stdout
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 6:
                continue
            fs = parts[0]; mount = parts[5]
            if fs.startswith(("tmpfs", "devtmpfs", "udev")):
                continue
            try:
                tot = int(parts[1]); used = int(parts[2])
                pct = round(used / tot * 100, 1) if tot else 0.0
                if pct > DISK_THRESHOLD:
                    disks_over.append(f"{mount} {pct}%")
            except ValueError:
                pass
    except Exception:
        pass
    try:
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
    except Exception:
        load = 0.0
    return {
        "cpu_percent":     cpu_pct,
        "load_1min":       load,
        "memory_percent":  round(used_kb / tot_kb * 100, 1) if tot_kb else 0.0,
        "memory_used_gb":  round(used_kb  / 1048576, 2),
        "memory_total_gb": round(tot_kb   / 1048576, 2),
        "disks_over_threshold": disks_over,
    }


def collect_user_summary() -> Dict:
    total = 0; shell_users = 0
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.strip().split(":")
                if len(p) >= 7 and int(p[2]) >= 1000:
                    total += 1
                    if p[6] not in ("/sbin/nologin", "/bin/false", "/usr/sbin/nologin"):
                        shell_users += 1
    except OSError:
        pass
    return {"total_regular_users": total, "users_with_shell": shell_users}


def collect_port_summary() -> Dict:
    try:
        out = subprocess.run(["ss", "-tlunp"],
                             capture_output=True, text=True, timeout=10).stdout
        ports = set()
        for line in out.splitlines()[1:]:
            p = line.split()
            if len(p) >= 5:
                port = p[4].rsplit(":", 1)[-1]
                if port.isdigit():
                    ports.add(f"{p[0]}:{port}")
        return {"total_listening_ports": len(ports)}
    except Exception:
        return {"total_listening_ports": 0}


def collect_failed_logins_inline() -> Dict:
    since = (datetime.datetime.now() - datetime.timedelta(hours=24)
             ).strftime("%Y-%m-%d %H:%M:%S")
    try:
        out = subprocess.run(
            ["journalctl", "_COMM=sshd", f"--since={since}", "--no-pager", "-q"],
            capture_output=True, text=True, timeout=30).stdout
        count = sum(1 for l in out.splitlines() if "Failed" in l or "Invalid" in l)
        return {"failed_logins_24h": count}
    except Exception:
        return {"failed_logins_24h": 0}


def _collect_all() -> Tuple[Dict, List[str]]:
    sys_json    = _load_json(SYSTEM_MONITOR_OUTPUT) or {}
    user_json   = _load_json(USER_AUDIT_OUTPUT)     or {}
    ports_json  = _load_json(PORTS_AUDIT_OUTPUT)    or {}
    logins_json = _load_json(FAILED_LOGIN_OUTPUT)   or {}
    inline_sys   = collect_system_metrics()
    inline_users = collect_user_summary()
    inline_ports = collect_port_summary()
    inline_logins = collect_failed_logins_inline()
    sys_metrics = sys_json.get("data") or inline_sys
    users       = user_json.get("data", {}).get("summary") or inline_users
    ports       = ports_json.get("data", {}).get("summary") or inline_ports
    logins      = logins_json.get("data") or inline_logins
    alerts = []
    cpu_pct = (sys_json.get("data", {}).get("cpu", {}).get("percent")
               or inline_sys["cpu_percent"])
    mem_pct = (sys_json.get("data", {}).get("memory", {}).get("percent")
               or inline_sys["memory_percent"])
    if cpu_pct > CPU_THRESHOLD:
        alerts.append(f"CPU at {cpu_pct}%")
    if mem_pct > MEMORY_THRESHOLD:
        alerts.append(f"Memory at {mem_pct}%")
    for disk_alert in inline_sys.get("disks_over_threshold", []):
        alerts.append(f"Disk {disk_alert}")
    high_risk = user_json.get("data", {}).get("summary", {}).get("high_risk", 0)
    if high_risk > 0:
        alerts.append(f"{high_risk} HIGH risk user(s) found")
    failed = logins_json.get("data", {}).get("failed_count") or inline_logins["failed_logins_24h"]
    if failed > 10:
        alerts.append(f"{failed} failed logins in last 24h")
    return {
        "report_date":    datetime.datetime.now().strftime("%Y-%m-%d"),
        "system_metrics": sys_metrics,
        "users":          users,
        "ports":          ports,
        "failed_logins":  logins,
        "summary": {"alerts": len(alerts), "cpu_pct": cpu_pct,
            "mem_pct": mem_pct, "high_risk_users": high_risk,
            "failed_logins_24h": failed},
    }, alerts



def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=SCRIPT_NAME + " — see README.md.")
    p.add_argument("--dry-run",     action="store_true")
    p.add_argument("--maintenance", action="store_true")
    p.add_argument("--version",     action="version", version=f"Version={VERSION}")
    return p.parse_args()


def main() -> None:
    global _lock_fd
    args = parse_args()
    setup_logging()
    rotate_logs()
    if args.maintenance:
        toggle_maintenance()
    if args.dry_run:
        print(json.dumps({
            "timestamp": _now_iso(), "host": resolve_hostname(),
            "script": SCRIPT_NAME, "version": VERSION, "status": "DRY_RUN",
            "dry_run": {"cpu_threshold": CPU_THRESHOLD, "memory_threshold": MEMORY_THRESHOLD, "disk_threshold": DISK_THRESHOLD, "maintenance": is_maintenance()},
            "alerts": [], "duration_seconds": round(time.time() - _start_time, 2),
        }, indent=2))
        sys.exit(0)
    _lock_fd = acquire_lock()
    if _lock_fd is None:
        sys.exit(0)
    def _cleanup(signum, frame):
        release_lock(_lock_fd)
        sys.exit(0)
    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT,  _cleanup)
    log.info("START host=%s", resolve_hostname())
    try:
        data, alerts   = _collect_all()
        current_status = get_status()
        new_status     = "ALERT" if alerts else "OK"
        if alerts and current_status != "ALERT":
            set_status("ALERT")
            alert(chr(10).join(alerts))
        elif not alerts and current_status == "ALERT":
            set_status("OK")
            send_recovery_mail()
        else:
            set_status(new_status)
        result = {
            "timestamp": _now_iso(), "host": resolve_hostname(),
            "script": SCRIPT_NAME, "version": VERSION, "status": new_status,
            "data": data, "alerts": alerts,
            "duration_seconds": round(time.time() - _start_time, 2),
        }
        exit_code = 1 if alerts else 0
    except Exception as exc:
        log.error("Unhandled exception: %s", exc, exc_info=True)
        result = {
            "timestamp": _now_iso(), "host": resolve_hostname(),
            "script": SCRIPT_NAME, "version": VERSION, "status": "ERROR",
            "data": {}, "alerts": [str(exc)],
            "duration_seconds": round(time.time() - _start_time, 2),
        }
        exit_code = 2
    finally:
        release_lock(_lock_fd)
    log.info("END status=%s duration=%.2fs", result["status"], result["duration_seconds"])
    print(json.dumps(result, indent=2))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
