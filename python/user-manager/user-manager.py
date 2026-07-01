#!/usr/bin/env python3

###########################################################################
# user-manager.py                                                         #
# Manages local system users: add, remove, lock, unlock, list, set-shell, #
# and add-key. All operations produce JSON output and append to an        #
# append-only JSONL audit trail. Uses useradd/userdel/usermod.            #
# Author: Filcu Alexandru                                                 #
###########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Defaults for new users
DEFAULT_SHELL  = "/bin/bash"
DEFAULT_GROUPS = []          # additional groups, e.g. ["docker", "sudo"]
CREATE_HOME    = True
SKEL_DIR       = "/etc/skel"

# Audit log (append-only JSONL)
AUDIT_LOG = os.path.join(SCRIPT_DIR, "user-manager-audit.jsonl")

# Logging
LOG_RETENTION_DAYS = 14

# Host
HOSTNAME_LABEL = ""

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "user-manager.lock")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "user-manager"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "user-manager-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "user-manager-execution.log")
_start_time    = time.time()
_lock_fd: Optional[object] = None

log = logging.getLogger(SCRIPT_NAME)


def _now_iso() -> str:
    """Return the current UTC time as an ISO-8601 string."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def setup_logging() -> None:
    """Configure the execution and error log handlers."""
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
    """Delete log files older than the retention window."""
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
    """Return the configured or system hostname."""
    return HOSTNAME_LABEL if HOSTNAME_LABEL else socket.gethostname()


def acquire_lock() -> Optional[object]:
    """Acquire a non-blocking instance lock."""
    try:
        fd = open(LOCK_FILE, "w")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except (IOError, OSError):
        return None


def release_lock(fd: object) -> None:
    """Release and remove the instance lock."""
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()
        os.remove(LOCK_FILE)
    except OSError:
        pass


def should_send_email() -> bool:
    """Return True if the email rate-limit interval has elapsed."""
    try:
        with open(STATE_FILE) as f:
            return (time.time() - float(f.read().strip())) >= EMAIL_INTERVAL
    except Exception:
        return True


def mark_email_sent() -> None:
    """Record the timestamp of the last sent email."""
    try:
        with open(STATE_FILE, "w") as f:
            f.write(str(time.time()))
    except OSError:
        pass


def last_email_age() -> str:
    """Return a human-readable age since the last email."""
    try:
        with open(STATE_FILE) as f:
            return f"{int(time.time() - float(f.read().strip()))}s ago"
    except Exception:
        return "never"


def get_status() -> str:
    """Read the persisted OK/ALERT status."""
    try:
        with open(STATUS_FILE) as f:
            s = f.read().strip()
        return s if s in ("OK", "ALERT") else "OK"
    except Exception:
        return "OK"


def set_status(status: str) -> None:
    """Persist the OK/ALERT status."""
    try:
        with open(STATUS_FILE, "w") as f:
            f.write(status)
    except OSError:
        pass


def send_recovery_mail(body: str = "") -> None:
    """Send a one-off recovery email when the alert clears."""
    if not ALERT_EMAIL:
        return
    _send_mail(
        f"{SCRIPT_NAME} recovery on {resolve_hostname()}",
        body or f"All checks passed on {resolve_hostname()}.",
    )
    log.warning("RECOVERY EMAIL sent to %s", ALERT_EMAIL)


def is_maintenance() -> bool:
    """Return True while maintenance mode is active."""
    return os.path.exists(MAINTENANCE_FILE)


def toggle_maintenance() -> None:
    """Toggle maintenance mode and exit."""
    if os.path.exists(MAINTENANCE_FILE):
        os.remove(MAINTENANCE_FILE)
        print(json.dumps({"maintenance": "disabled"}))
    else:
        open(MAINTENANCE_FILE, "w").close()
        print(json.dumps({"maintenance": "enabled"}))
    sys.exit(0)


def _send_mail(subject: str, body: str) -> None:
    """Send an email via the mail command (best effort)."""
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
    """Log an alert and send a rate-limited email."""
    if is_maintenance():
        return
    log.warning("ALERT %s", detail)
    if ALERT_EMAIL and should_send_email():
        _send_mail(f"Alert: {SCRIPT_NAME} on {resolve_hostname()}", detail)
        mark_email_sent()
        log.warning("EMAIL sent to %s", ALERT_EMAIL)



import pwd as _pwdm, grp as _grpm


def audit_log(action: str, username: str, result: str, detail: str = "") -> None:
    """Append an entry to the audit trail."""
    entry = {"timestamp": _now_iso(), "host": resolve_hostname(),
        "operator": os.environ.get("SUDO_USER", os.environ.get("USER", "unknown")),
        "action": action, "username": username, "result": result, "detail": detail}
    try:
        with open(AUDIT_LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass
    log.info("AUDIT action=%s user=%s result=%s", action, username, result)


def user_exists(username: str) -> bool:
    """Return True if the user account exists."""
    try:
        _pwdm.getpwnam(username); return True
    except KeyError:
        return False


def _run(cmd: List[str]) -> Tuple[bool, str]:
    """Run a command and return its stdout, or '' on error."""
    try:
        out = subprocess.run(cmd, capture_output=True, text=True)
        return out.returncode == 0, out.stderr.strip()
    except Exception as exc:
        return False, str(exc)


def add_user(username: str, shell: str = "", groups: List[str] = None,
             comment: str = "", ssh_key: str = "") -> Dict:
    """Add user."""
    if user_exists(username):
        return {"success": False, "error": f"User {username} already exists"}
    cmd = ["useradd"] + (["-m", "-k", SKEL_DIR] if CREATE_HOME else [])
    cmd += ["-s", shell or DEFAULT_SHELL]
    if comment:
        cmd += ["-c", comment]
    effective_groups = groups if groups is not None else DEFAULT_GROUPS
    if effective_groups:
        cmd += ["-G", ",".join(effective_groups)]
    cmd.append(username)
    ok, err = _run(cmd)
    if not ok:
        audit_log("add_user", username, "FAILED", err)
        return {"success": False, "error": err}
    if ssh_key:
        kr = add_ssh_key(username, ssh_key)
        if not kr["success"]:
            audit_log("add_user", username, "PARTIAL", kr["error"])
            return {"success": True, "ssh_key_warning": kr["error"]}
    audit_log("add_user", username, "SUCCESS")
    return {"success": True}


def remove_user(username: str, remove_home: bool = False) -> Dict:
    """Remove user."""
    if not user_exists(username):
        return {"success": False, "error": f"User {username} does not exist"}
    cmd = ["userdel"] + (["-r"] if remove_home else []) + [username]
    ok, err = _run(cmd)
    if not ok:
        audit_log("remove_user", username, "FAILED", err)
        return {"success": False, "error": err}
    audit_log("remove_user", username, "SUCCESS", f"remove_home={remove_home}")
    return {"success": True}


def lock_user(username: str) -> Dict:
    """Lock user."""
    if not user_exists(username):
        return {"success": False, "error": f"User {username} does not exist"}
    ok, err = _run(["usermod", "-L", username])
    if not ok:
        audit_log("lock_user", username, "FAILED", err)
        return {"success": False, "error": err}
    audit_log("lock_user", username, "SUCCESS")
    return {"success": True}


def unlock_user(username: str) -> Dict:
    """Unlock user."""
    if not user_exists(username):
        return {"success": False, "error": f"User {username} does not exist"}
    ok, err = _run(["usermod", "-U", username])
    if not ok:
        audit_log("unlock_user", username, "FAILED", err)
        return {"success": False, "error": err}
    audit_log("unlock_user", username, "SUCCESS")
    return {"success": True}


def set_shell(username: str, shell: str) -> Dict:
    """Set the shell."""
    if not user_exists(username):
        return {"success": False, "error": f"User {username} does not exist"}
    if not os.path.isfile(shell):
        return {"success": False, "error": f"Shell {shell} not found"}
    ok, err = _run(["usermod", "-s", shell, username])
    if not ok:
        audit_log("set_shell", username, "FAILED", err)
        return {"success": False, "error": err}
    audit_log("set_shell", username, "SUCCESS", f"shell={shell}")
    return {"success": True}


def add_ssh_key(username: str, public_key: str) -> Dict:
    """Add SSH key."""
    try:
        user_info = _pwdm.getpwnam(username)
    except KeyError:
        return {"success": False, "error": f"User {username} not found"}
    ssh_dir   = os.path.join(user_info.pw_dir, ".ssh")
    auth_file = os.path.join(ssh_dir, "authorized_keys")
    try:
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        os.chown(ssh_dir, user_info.pw_uid, user_info.pw_gid)
        existing = ""
        if os.path.isfile(auth_file):
            with open(auth_file) as f:
                existing = f.read()
        key_b64 = public_key.split()[1] if len(public_key.split()) >= 2 else ""
        if key_b64 and key_b64 in existing:
            return {"success": False, "error": "Key already present"}
        with open(auth_file, "a") as f:
            f.write(public_key.strip() + "\n")
        os.chmod(auth_file, 0o600)
        os.chown(auth_file, user_info.pw_uid, user_info.pw_gid)
    except (OSError, PermissionError) as exc:
        audit_log("add_ssh_key", username, "FAILED", str(exc))
        return {"success": False, "error": str(exc)}
    audit_log("add_ssh_key", username, "SUCCESS")
    return {"success": True}


def list_users(min_uid: int = 1000) -> List[Dict]:
    """List users."""
    users = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.strip().split(":")
                if len(p) >= 7 and int(p[2]) >= min_uid:
                    users.append({"username": p[0], "uid": int(p[2]),
                                  "home": p[5], "shell": p[6]})
    except OSError:
        pass
    return sorted(users, key=lambda u: u["uid"])


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    p = argparse.ArgumentParser(
        description="user-manager — manage local users with JSON output and audit trail.")
    p.add_argument("--version", action="version", version=f"Version={VERSION}")
    sub = p.add_subparsers(dest="command", required=True)
    add_p = sub.add_parser("add",       help="Create a new user")
    add_p.add_argument("username")
    add_p.add_argument("--shell",    default=DEFAULT_SHELL)
    add_p.add_argument("--groups",   default="")
    add_p.add_argument("--comment",  default="")
    add_p.add_argument("--ssh-key",  default="")
    add_p.add_argument("--dry-run",  action="store_true")
    rm_p  = sub.add_parser("remove",    help="Remove a user")
    rm_p.add_argument("username")
    rm_p.add_argument("--remove-home", action="store_true")
    rm_p.add_argument("--dry-run",     action="store_true")
    lk_p  = sub.add_parser("lock",      help="Lock a user account")
    lk_p.add_argument("username"); lk_p.add_argument("--dry-run", action="store_true")
    ul_p  = sub.add_parser("unlock",    help="Unlock a user account")
    ul_p.add_argument("username"); ul_p.add_argument("--dry-run", action="store_true")
    ls_p  = sub.add_parser("list",      help="List regular users")
    ls_p.add_argument("--min-uid", type=int, default=1000)
    sh_p  = sub.add_parser("set-shell", help="Change login shell")
    sh_p.add_argument("username"); sh_p.add_argument("shell")
    sh_p.add_argument("--dry-run", action="store_true")
    ak_p  = sub.add_parser("add-key",   help="Add SSH public key for user")
    ak_p.add_argument("username"); ak_p.add_argument("public_key")
    ak_p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def main() -> None:
    """Program entry point: run the check and print the JSON result."""
    global _lock_fd
    args = parse_args()
    setup_logging()
    rotate_logs()
    _lock_fd = acquire_lock()
    if _lock_fd is None:
        print(json.dumps({"error": "Another instance is running"}))
        sys.exit(2)
    def _cleanup(signum, frame):
        """Release the lock and exit on signal."""
        release_lock(_lock_fd)
        sys.exit(0)
    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT,  _cleanup)
    log.info("START command=%s", args.command)
    dry = getattr(args, "dry_run", False)
    try:
        if args.command == "list":
            users = list_users(args.min_uid)
            result = {"timestamp": _now_iso(), "host": resolve_hostname(),
                "script": SCRIPT_NAME, "version": VERSION, "status": "OK",
                "data": {"users": users, "total": len(users)},
                "alerts": [], "duration_seconds": round(time.time() - _start_time, 2)}
        else:
            username = getattr(args, "username", "")
            if dry:
                op_result = {"success": True, "dry_run": True,
                             "would_run": args.command, "username": username}
            elif args.command == "add":
                groups = [g for g in args.groups.split(",") if g] if args.groups else []
                op_result = add_user(username, args.shell, groups, args.comment,
                                     getattr(args, "ssh_key", ""))
            elif args.command == "remove":
                op_result = remove_user(username, args.remove_home)
            elif args.command == "lock":
                op_result = lock_user(username)
            elif args.command == "unlock":
                op_result = unlock_user(username)
            elif args.command == "set-shell":
                op_result = set_shell(username, args.shell)
            elif args.command == "add-key":
                op_result = add_ssh_key(username, args.public_key)
            else:
                op_result = {"success": False, "error": "Unknown command"}
            status = "OK" if op_result.get("success") else "ERROR"
            result = {"timestamp": _now_iso(), "host": resolve_hostname(),
                "script": SCRIPT_NAME, "version": VERSION, "status": status,
                "data": {"command": args.command, "username": username,
                         "result": op_result},
                "alerts": [] if op_result.get("success") else [op_result.get("error","")],
                "duration_seconds": round(time.time() - _start_time, 2)}
        exit_code = 0 if result["status"] == "OK" else 1
    except Exception as exc:
        log.error("Unhandled: %s", exc, exc_info=True)
        result = {"timestamp": _now_iso(), "host": resolve_hostname(),
            "script": SCRIPT_NAME, "version": VERSION, "status": "ERROR",
            "data": {}, "alerts": [str(exc)],
            "duration_seconds": round(time.time() - _start_time, 2)}
        exit_code = 2
    finally:
        release_lock(_lock_fd)
    log.info("END command=%s status=%s", args.command, result["status"])
    print(json.dumps(result, indent=2))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()

