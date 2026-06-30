#!/usr/bin/env python3

#########################################################################
# cron-audit.py                                                         #
# Inventories all crontab entries across the system: /etc/crontab,      #
# /etc/cron.d/*, /etc/cron.{hourly,daily,weekly,monthly}/, and all user #
# crontabs in /var/spool/cron/crontabs/. Validates that each referenced #
# script exists and is executable. Outputs a structured JSON report.    #
# Author: Filcu Alexandru                                               #
#########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "cron-audit.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "cron-audit.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "cron-audit.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "cron-audit.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "cron-audit"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "cron-audit-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "cron-audit-execution.log")
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



def _parse_crontab_file(path: str, owner: str) -> List[Dict]:
    entries = []
    try:
        with open(path) as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#") or "=" in line[:20]:
                    continue
                parts = line.split()
                if len(parts) < 6:
                    continue
                schedule = " ".join(parts[:5])
                command  = " ".join(parts[5:])
                script   = parts[6] if len(parts) > 6 else parts[5]
                entries.append({"file": path, "owner": owner, "line": lineno,
                    "schedule": schedule, "command": command, "script_path": script})
    except (OSError, PermissionError):
        pass
    return entries


def collect_system_crontabs() -> List[Dict]:
    entries = []
    if os.path.isfile("/etc/crontab"):
        entries.extend(_parse_crontab_file("/etc/crontab", "root"))
    if os.path.isdir("/etc/cron.d"):
        for fname in os.listdir("/etc/cron.d"):
            fpath = os.path.join("/etc/cron.d", fname)
            if os.path.isfile(fpath):
                entries.extend(_parse_crontab_file(fpath, "root"))
    return entries


def collect_cron_dirs() -> List[Dict]:
    entries = []
    for freq in ("hourly", "daily", "weekly", "monthly"):
        cron_dir = f"/etc/cron.{freq}"
        if not os.path.isdir(cron_dir):
            continue
        for fname in os.listdir(cron_dir):
            fpath = os.path.join(cron_dir, fname)
            if os.path.isfile(fpath):
                entries.append({"file": cron_dir, "owner": "root",
                    "frequency": freq, "script_path": fpath, "command": fpath})
    return entries


def collect_user_crontabs() -> List[Dict]:
    entries = []
    spool   = "/var/spool/cron/crontabs"
    if not os.path.isdir(spool):
        return entries
    for user in os.listdir(spool):
        entries.extend(_parse_crontab_file(os.path.join(spool, user), user))
    return entries


def validate_entries(entries: List[Dict]) -> List[Dict]:
    issues = []
    for entry in entries:
        script = entry.get("script_path", "")
        if not script or not script.startswith("/"):
            continue
        if not os.path.isfile(script):
            issues.append({"severity": "WARNING", "file": entry["file"],
                "owner": entry["owner"], "script": script,
                "issue": "script_not_found"})
        elif not os.access(script, os.X_OK):
            issues.append({"severity": "INFO", "file": entry["file"],
                "owner": entry["owner"], "script": script,
                "issue": "script_not_executable"})
    return issues


def _collect_all() -> Tuple[Dict, List[str]]:
    entries = (collect_system_crontabs() + collect_cron_dirs() +
               collect_user_crontabs())
    issues  = validate_entries(entries)
    alerts  = [f"{i['issue']} for {i['script']} (owner: {i['owner']})"
               for i in issues if i["severity"] == "WARNING"]
    return {
        "total_entries": len(entries),
        "entries":       entries,
        "issues":        issues,
        "summary": {
            "total":           len(entries),
            "system_entries":  sum(1 for e in entries if e["owner"] == "root"),
            "user_entries":    sum(1 for e in entries if e["owner"] != "root"),
            "warnings":        sum(1 for i in issues if i["severity"] == "WARNING"),
        },
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
            "dry_run": {"cron_d_exists": os.path.isdir("/etc/cron.d"), "spool_exists": os.path.isdir("/var/spool/cron/crontabs"), "maintenance": is_maintenance()},
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
