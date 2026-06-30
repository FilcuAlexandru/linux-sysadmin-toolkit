#!/usr/bin/env python3

###############################################################################
# security-report.py                                                          #
# Aggregates security-relevant data: failed SSH logins with top attacker IPs, #
# listening ports vs. expected list, high-risk users from /etc/passwd and     #
# /etc/sudoers, and recent sudo usage from auth logs. Designed as a daily     #
# security snapshot for Linux systems.                                        #
# Author: Filcu Alexandru                                                     #
###############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, re as _re_sec
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Expected ports — unexpected ports trigger an alert
EXPECTED_PORTS         = ["tcp:22", "tcp:80", "tcp:443"]

# Failed login threshold
FAILED_LOGIN_THRESHOLD = 10   # alert when failed logins in last 24h exceed this
WINDOW_HOURS           = 24   # hours to look back for failed logins

# User risk
MIN_UID = 1000   # minimum UID for regular users

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "security-report.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "security-report.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "security-report.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "security-report.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "security-report"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "security-report-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "security-report-execution.log")
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



def collect_failed_logins() -> Dict:
    since = (datetime.datetime.now() - datetime.timedelta(hours=WINDOW_HOURS)
             ).strftime("%Y-%m-%d %H:%M:%S")
    lines = []
    try:
        out = subprocess.run(
            ["journalctl", "_COMM=sshd", f"--since={since}", "--no-pager", "-q"],
            capture_output=True, text=True, timeout=30).stdout
        lines = [l for l in out.splitlines()
                 if _re_sec.search(r"Failed|Invalid|authentication failure", l)]
    except Exception:
        pass
    if not lines and os.path.isfile("/var/log/auth.log"):
        try:
            with open("/var/log/auth.log") as f:
                lines = [l.strip() for l in f
                         if _re_sec.search(r"Failed password|Invalid user", l)]
        except (OSError, PermissionError):
            pass
    ips: Dict[str, int] = {}
    for line in lines:
        m = _re_sec.search(r"from\s+([\d.]+)", line)
        if m:
            ips[m.group(1)] = ips.get(m.group(1), 0) + 1
    top_ips = sorted(ips.items(), key=lambda x: -x[1])[:5]
    return {"count": len(lines),
            "top_ips": [{"ip": k, "count": v} for k, v in top_ips],
            "window_hours": WINDOW_HOURS}


def collect_ports() -> Dict:
    listening = []
    try:
        out = subprocess.run(["ss", "-tlunp"],
                             capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines()[1:]:
            p = line.split()
            if len(p) >= 5:
                port = p[4].rsplit(":", 1)[-1]
                if port.isdigit():
                    listening.append(f"{p[0]}:{port}")
    except Exception:
        pass
    listening  = sorted(set(listening))
    unexpected = [p for p in listening if EXPECTED_PORTS and p not in EXPECTED_PORTS]
    return {"listening": listening, "unexpected": unexpected, "expected": EXPECTED_PORTS}


def collect_risky_users() -> Dict:
    sudo_users: Dict[str, bool] = {}
    files = []
    if os.path.isfile("/etc/sudoers"):
        files.append("/etc/sudoers")
    if os.path.isdir("/etc/sudoers.d"):
        for f in os.listdir("/etc/sudoers.d"):
            files.append(os.path.join("/etc/sudoers.d", f))
    for fpath in files:
        try:
            with open(fpath) as f:
                for line in f:
                    m = _re_sec.match(
                        r"^(\w+)\s+ALL\s*=\s*\(ALL(?::ALL)?\)\s*(NOPASSWD:\s*)?ALL",
                        line.strip(), _re_sec.IGNORECASE)
                    if m:
                        sudo_users[m.group(1)] = bool(m.group(2))
        except (OSError, PermissionError):
            pass
    risky = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.strip().split(":")
                if len(p) < 7 or int(p[2]) < MIN_UID:
                    continue
                issues = []
                if p[0] in sudo_users:
                    issues.append("sudo_nopasswd" if sudo_users[p[0]] else "sudo_access")
                if issues:
                    risky.append({"username": p[0], "uid": int(p[2]),
                                  "shell": p[6], "issues": issues})
    except OSError:
        pass
    return {"risky_users": risky, "total_risky": len(risky)}


def collect_sudo_usage() -> List[str]:
    for source in (["journalctl", "_COMM=sudo", "--since=yesterday", "--no-pager", "-q"],):
        try:
            out = subprocess.run(source, capture_output=True, text=True, timeout=15).stdout
            entries = [l.strip() for l in out.splitlines() if "COMMAND" in l][:20]
            if entries:
                return entries
        except Exception:
            pass
    if os.path.isfile("/var/log/auth.log"):
        try:
            with open("/var/log/auth.log") as f:
                return [l.strip() for l in f if "sudo" in l and "COMMAND" in l][-20:]
        except (OSError, PermissionError):
            pass
    return []


def _collect_all() -> Tuple[Dict, List[str]]:
    failed = collect_failed_logins()
    ports  = collect_ports()
    users  = collect_risky_users()
    sudo   = collect_sudo_usage()
    alerts = []
    if failed["count"] > FAILED_LOGIN_THRESHOLD:
        alerts.append(f"{failed['count']} failed SSH logins in last {WINDOW_HOURS}h "
                      f"(threshold {FAILED_LOGIN_THRESHOLD})")
    for p in ports["unexpected"]:
        alerts.append(f"Unexpected open port: {p}")
    for u in users["risky_users"]:
        if "sudo_nopasswd" in u.get("issues", []):
            alerts.append(f"User {u['username']} has NOPASSWD sudo access")
    return {
        "failed_logins": failed,
        "ports":         ports,
        "risky_users":   users,
        "recent_sudo":   sudo,
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
            "dry_run": {"failed_login_threshold": FAILED_LOGIN_THRESHOLD, "window_hours": WINDOW_HOURS, "expected_ports": EXPECTED_PORTS, "maintenance": is_maintenance(), "current_status": get_status()},
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
