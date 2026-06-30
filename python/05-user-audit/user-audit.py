#!/usr/bin/env python3

#########################################################################
# user-audit.py                                                         #
# Audits system users by parsing /etc/passwd, /etc/shadow, /etc/group,  #
# and /etc/sudoers. Cross-references with last/lastb login history.     #
# Assigns a risk score per user (HIGH/MEDIUM/LOW) based on sudo access, #
# missing passwords, locked accounts, and failed login counts.          #
# Author: Filcu Alexandru                                               #
#########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, re as _re, grp as _grp, pwd as _pwd
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Audit configuration
MIN_UID              = 1000   # minimum UID for regular users
INCLUDE_SYSTEM_USERS = False  # set True to include system accounts
PASSWORD_WARN_DAYS   = 14     # flag users whose password expires within this
LAST_LINES           = 500    # lines to read from last output

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "user-audit.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "user-audit.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "user-audit.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "user-audit.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "user-audit"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "user-audit-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "user-audit-execution.log")
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



def parse_passwd() -> List[Dict]:
    users = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                p = line.split(":")
                if len(p) >= 7:
                    users.append({"username": p[0], "uid": int(p[2]),
                                  "gid": int(p[3]), "home": p[5], "shell": p[6]})
    except OSError:
        pass
    return users


def parse_shadow() -> Dict[str, Dict]:
    shadow: Dict[str, Dict] = {}
    def _si(s: str) -> Optional[int]:
        try:
            return int(s) if s else None
        except ValueError:
            return None
    try:
        with open("/etc/shadow") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                p = line.split(":")
                if len(p) < 9:
                    continue
                pw = p[1]
                shadow[p[0]] = {
                    "has_password": pw not in ("", "*", "!", "!!"),
                    "locked":       pw.startswith(("!", "*")),
                    "last_change":  _si(p[2]),
                    "max_days":     _si(p[4]),
                    "expire_epoch": _si(p[7]),
                }
    except (OSError, PermissionError):
        pass
    return shadow


def parse_groups() -> Dict[str, List[str]]:
    membership: Dict[str, List[str]] = {}
    try:
        with open("/etc/group") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                p = line.split(":")
                if len(p) >= 4:
                    for m in [x for x in p[3].split(",") if x]:
                        membership.setdefault(m, []).append(p[0])
    except OSError:
        pass
    return membership


def parse_sudoers() -> Dict[str, Dict]:
    sudo_users: Dict[str, Dict] = {}
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
                    line = line.strip()
                    if line.startswith("#") or not line:
                        continue
                    m = _re.match(
                        r"^(\w+)\s+ALL\s*=\s*\(ALL(?::ALL)?\)\s*(NOPASSWD:\s*)?ALL",
                        line, _re.IGNORECASE)
                    if m:
                        sudo_users[m.group(1)] = {"sudo": True,
                                                   "nopasswd": bool(m.group(2))}
        except (OSError, PermissionError):
            pass
    for gname in ("wheel", "sudo"):
        try:
            g = _grp.getgrnam(gname)
            for member in g.gr_mem:
                if member not in sudo_users:
                    sudo_users[member] = {"sudo": True, "nopasswd": False,
                                          "via_group": gname}
        except (KeyError, AttributeError):
            pass
    return sudo_users


def parse_last() -> Dict[str, str]:
    last_login: Dict[str, str] = {}
    try:
        out = subprocess.run(["last", "-n", str(LAST_LINES), "-w"],
                             capture_output=True, text=True, timeout=15).stdout
        for line in out.splitlines():
            p = line.split()
            if len(p) < 5 or p[0] in ("reboot", "wtmp", ""):
                continue
            if p[0] not in last_login:
                last_login[p[0]] = " ".join(p[3:7])
    except Exception:
        pass
    return last_login


def parse_lastb() -> Dict[str, int]:
    failed: Dict[str, int] = {}
    try:
        out = subprocess.run(["lastb", "-n", "200", "-w"],
                             capture_output=True, text=True, timeout=15).stdout
        for line in out.splitlines():
            p = line.split()
            if p and p[0] not in ("btmp", ""):
                failed[p[0]] = failed.get(p[0], 0) + 1
    except Exception:
        pass
    return failed


def score_user(user: Dict, shadow_entry: Optional[Dict], groups: List[str],
               sudo_info: Optional[Dict], last_login: Optional[str],
               failed_logins: int) -> Tuple[str, List[str]]:
    findings = []; score = 0
    has_shell = user["shell"] not in ("/sbin/nologin", "/bin/false",
                                       "/usr/sbin/nologin", "")
    if sudo_info:
        if sudo_info.get("nopasswd"):
            findings.append("sudo_nopasswd"); score += 30
        else:
            findings.append("sudo_access"); score += 10
    if shadow_entry:
        if not shadow_entry["has_password"] and has_shell:
            findings.append("no_password_with_shell"); score += 40
        if shadow_entry["locked"]:
            findings.append("account_locked")
        if shadow_entry.get("max_days") and shadow_entry["max_days"] > 0:
            last_chg = shadow_entry.get("last_change") or 0
            exp_in   = last_chg + shadow_entry["max_days"] - (int(time.time()) // 86400)
            if exp_in <= PASSWORD_WARN_DAYS:
                findings.append(f"password_expires_in_{max(0, exp_in)}_days"); score += 5
    if not last_login and has_shell and user["uid"] >= MIN_UID:
        findings.append("never_logged_in"); score += 5
    if failed_logins >= 10:
        findings.append(f"high_failed_logins_{failed_logins}"); score += 10
    priv = [g for g in groups if g in {"wheel", "sudo", "docker", "adm", "root"}]
    if priv:
        findings.append(f"privileged_groups:{','.join(priv)}")
    risk = "HIGH" if score >= 30 else "MEDIUM" if score >= 15 else "LOW"
    return risk, findings


def _collect_all() -> Tuple[Dict, List[str]]:
    passwd   = parse_passwd()
    shadow   = parse_shadow()
    groups   = parse_groups()
    sudoers  = parse_sudoers()
    last_map = parse_last()
    lastb    = parse_lastb()
    audited  = []
    for user in passwd:
        if not INCLUDE_SYSTEM_USERS and user["uid"] < MIN_UID:
            continue
        shadow_entry = shadow.get(user["username"])
        user_groups  = groups.get(user["username"], [])
        sudo_info    = sudoers.get(user["username"])
        last_login   = last_map.get(user["username"])
        failed       = lastb.get(user["username"], 0)
        risk, findings = score_user(user, shadow_entry, user_groups, sudo_info,
                                    last_login, failed)
        audited.append({"username": user["username"], "uid": user["uid"],
            "shell": user["shell"], "home": user["home"], "groups": user_groups,
            "sudo": bool(sudo_info),
            "sudo_nopasswd": sudo_info.get("nopasswd", False) if sudo_info else False,
            "last_login": last_login, "failed_logins": failed,
            "locked": shadow_entry.get("locked", False) if shadow_entry else False,
            "risk": risk, "findings": findings})
    audited.sort(key=lambda u: ({"HIGH": 0, "MEDIUM": 1, "LOW": 2}.get(u["risk"], 3),
                                 u["username"]))
    high   = [u for u in audited if u["risk"] == "HIGH"]
    medium = [u for u in audited if u["risk"] == "MEDIUM"]
    alerts = [f"{u['username']} (risk=HIGH): {', '.join(u['findings'])}" for u in high]
    if alerts and should_send_email():
        _send_mail(f"User audit report on {resolve_hostname()}", chr(10).join(alerts))
        mark_email_sent()
    return {
        "users": audited,
        "summary": {"total": len(audited), "high_risk": len(high),
            "medium_risk": len(medium),
            "low_risk": len(audited) - len(high) - len(medium),
            "sudo_users": sum(1 for u in audited if u["sudo"]),
            "locked": sum(1 for u in audited if u["locked"])},
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
            "dry_run": {"min_uid": MIN_UID, "include_system": INCLUDE_SYSTEM_USERS, "shadow_readable": os.access("/etc/shadow", os.R_OK), "sudoers_readable": os.access("/etc/sudoers", os.R_OK)},
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
