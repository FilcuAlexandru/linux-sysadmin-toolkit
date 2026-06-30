#!/usr/bin/env python3

#############################################################################
# failed-login-analyzer.py                                                  #
# Counts failed SSH login attempts in a configurable time window and alerts #
# when the count exceeds THRESHOLD. Uses journalctl as primary source with  #
# /var/log/auth.log as fallback. Extracts top attacker IPs, targeted        #
# usernames, and generates an hourly heatmap. Status-aware alerting.        #
# Author: Filcu Alexandru                                                   #
#############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, re as _re
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Detection
WINDOW_MINUTES = 60    # look back this many minutes
THRESHOLD      = 10    # alert when failed count exceeds this
AUTH_LOG       = "/var/log/auth.log"  # fallback when journalctl unavailable
TOP_IPS        = 10    # number of top attacker IPs to include

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "failed-login-analyzer.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "failed-login-analyzer.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "failed-login-analyzer.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "failed-login-analyzer.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "failed-login-analyzer"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "failed-login-analyzer-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "failed-login-analyzer-execution.log")
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



def collect_from_journal(since_iso: str) -> List[str]:
    try:
        out = subprocess.run(
            ["journalctl", "_COMM=sshd", f"--since={since_iso}", "--no-pager", "-q"],
            capture_output=True, text=True, timeout=30).stdout
        return [l for l in out.splitlines()
                if _re.search(r"Failed|Invalid|authentication failure", l)]
    except Exception:
        return []


def collect_from_authlog() -> List[str]:
    if not AUTH_LOG or not os.path.isfile(AUTH_LOG):
        return []
    lines = []
    try:
        with open(AUTH_LOG) as f:
            for line in f:
                if _re.search(r"Failed password|Invalid user|authentication failure", line):
                    lines.append(line.strip())
    except (OSError, PermissionError):
        pass
    return lines


def collect_failed_lines() -> List[str]:
    since = (datetime.datetime.now() -
             datetime.timedelta(minutes=WINDOW_MINUTES)).strftime("%Y-%m-%d %H:%M:%S")
    lines = collect_from_journal(since)
    if not lines:
        lines = collect_from_authlog()
    return lines


def extract_ips(lines: List[str]) -> List[str]:
    return [m.group(1) for line in lines
            for m in [_re.search(r"from\s+([\d.]+)", line)] if m]


def extract_users(lines: List[str]) -> List[str]:
    return [m.group(1) for line in lines
            for m in [_re.search(r"(?:for|user)\s+(\w+)", line)] if m]


def build_hourly_map(lines: List[str]) -> Dict[str, int]:
    counts = {str(h).zfill(2): 0 for h in range(24)}
    for line in lines:
        m = _re.search(r"\b(\d{2}):\d{2}:\d{2}\b", line)
        if m and m.group(1) in counts:
            counts[m.group(1)] += 1
    return counts


def top_n(items: List[str], n: int) -> List[Dict]:
    counts: Dict[str, int] = {}
    for item in items:
        counts[item] = counts.get(item, 0) + 1
    return [{"value": k, "count": v}
            for k, v in sorted(counts.items(), key=lambda x: -x[1])[:n]]


def _collect_all() -> Tuple[Dict, List[str]]:
    lines  = collect_failed_lines()
    count  = len(lines)
    ips    = extract_ips(lines)
    users  = extract_users(lines)
    hourly = build_hourly_map(lines)
    alerts = []
    if count > THRESHOLD:
        alerts.append(f"{count} failed SSH logins in last {WINDOW_MINUTES}min "
                      f"(threshold: {THRESHOLD})")
    return {
        "window_minutes":     WINDOW_MINUTES,
        "threshold":          THRESHOLD,
        "failed_count":       count,
        "top_attacker_ips":   top_n(ips, TOP_IPS),
        "top_targeted_users": top_n(users, 5),
        "hourly_heatmap":     hourly,
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
            "dry_run": {"window_minutes": WINDOW_MINUTES, "threshold": THRESHOLD, "journalctl_ok": subprocess.run(["which","journalctl"],capture_output=True).returncode==0, "auth_log_exists": os.path.isfile(AUTH_LOG) if AUTH_LOG else False, "maintenance": is_maintenance(), "current_status": get_status()},
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
