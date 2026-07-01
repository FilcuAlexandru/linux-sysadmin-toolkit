#!/usr/bin/env python3

##########################################################################
# ssh-key-audit.py                                                       #
# Scans authorized_keys for all system users and reports weak algorithms #
# (RSA < MIN_RSA_BITS, DSA), keys without comments, and duplicate keys   #
# shared across multiple users. Extracts RSA modulus size from the       #
# base64 wire format using struct. Outputs a JSON risk report.           #
# Author: Filcu Alexandru                                                #
##########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, struct as _struct, base64 as _b64, pwd as _pwd2
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Thresholds
MIN_RSA_BITS   = 2048   # RSA keys below this bit count are flagged as weak
INCLUDE_SYSTEM = False  # set True to scan system users (uid < MIN_UID)
MIN_UID        = 1000   # minimum UID for regular users

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "ssh-key-audit.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "ssh-key-audit.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "ssh-key-audit.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "ssh-key-audit.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "ssh-key-audit"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "ssh-key-audit-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "ssh-key-audit-execution.log")
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



def _rsa_key_bits(b64_key: str) -> int:
    """Return the bit length of an RSA public key."""
    try:
        raw    = _b64.b64decode(b64_key)
        offset = 0
        def read_mpint() -> int:
            """Read an SSH multiple-precision integer."""
            nonlocal offset
            length = _struct.unpack(">I", raw[offset:offset + 4])[0]
            offset += 4
            val     = int.from_bytes(raw[offset:offset + length], "big")
            offset += length
            return val
        ktype_len = _struct.unpack(">I", raw[0:4])[0]
        offset    = 4 + ktype_len
        read_mpint()       # e (public exponent)
        n = read_mpint()   # n (modulus)
        return n.bit_length()
    except Exception:
        return 0


def parse_authorized_keys(path: str) -> List[Dict]:
    """Parse authorized keys."""
    keys = []
    try:
        with open(path) as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts    = line.split()
                if len(parts) < 2:
                    continue
                key_type = parts[0]
                b64_key  = parts[1]
                comment  = parts[2] if len(parts) > 2 else ""
                bits     = 0
                if key_type == "ssh-rsa":
                    bits = _rsa_key_bits(b64_key)
                elif key_type in ("ecdsa-sha2-nistp256",):
                    bits = 256
                elif key_type in ("ecdsa-sha2-nistp384",):
                    bits = 384
                elif key_type == "ssh-ed25519":
                    bits = 256
                weak = []
                if key_type == "ssh-dss":
                    weak.append("dsa_deprecated")
                if key_type == "ssh-rsa" and 0 < bits < MIN_RSA_BITS:
                    weak.append(f"rsa_{bits}bits_below_{MIN_RSA_BITS}")
                keys.append({"line": lineno, "type": key_type, "bits": bits,
                    "comment": comment, "b64_key": b64_key,
                    "weak": weak, "no_comment": not comment})
    except (OSError, PermissionError):
        pass
    return keys


def find_duplicates(user_keys: Dict[str, List[Dict]]) -> List[Dict]:
    """Find duplicates."""
    seen: Dict[str, List[str]] = {}
    for username, keys in user_keys.items():
        for k in keys:
            seen.setdefault(k["b64_key"], []).append(username)
    return [{"key_prefix": b64[:16] + "...", "found_in": users}
            for b64, users in seen.items() if len(users) > 1]


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    user_keys: Dict[str, List[Dict]] = {}
    findings  = []; alerts = []
    for user in _pwd2.getpwall():
        if not INCLUDE_SYSTEM and user.pw_uid < MIN_UID:
            continue
        auth_keys = os.path.join(user.pw_dir, ".ssh", "authorized_keys")
        if not os.path.isfile(auth_keys):
            continue
        keys = parse_authorized_keys(auth_keys)
        user_keys[user.pw_name] = keys
        for k in keys:
            if k["weak"]:
                findings.append({"username": user.pw_name, "file": auth_keys,
                    "line": k["line"], "type": k["type"], "bits": k["bits"],
                    "issues": k["weak"], "severity": "HIGH"})
                alerts.append(f"{user.pw_name}: weak key {k['type']} {k['bits']}bit "
                               f"({', '.join(k['weak'])})")
            if k["no_comment"]:
                findings.append({"username": user.pw_name, "line": k["line"],
                    "type": k["type"], "issues": ["no_comment"], "severity": "LOW"})
    duplicates = find_duplicates(user_keys)
    for dup in duplicates:
        alerts.append(f"Duplicate key shared by: {', '.join(dup['found_in'])}")
        findings.append({"key_prefix": dup["key_prefix"], "shared_by": dup["found_in"],
            "issues": ["duplicate_key"], "severity": "MEDIUM"})
    return {
        "users_with_keys": list(user_keys.keys()),
        "total_keys": sum(len(v) for v in user_keys.values()),
        "findings": findings, "duplicates": duplicates,
        "summary": {
            "total_users_with_keys": len(user_keys),
            "high_severity": sum(1 for f in findings if f.get("severity") == "HIGH"),
            "duplicate_keys": len(duplicates)},
    }, alerts



def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    p = argparse.ArgumentParser(description=SCRIPT_NAME + " — see README.md.")
    p.add_argument("--dry-run",     action="store_true")
    p.add_argument("--maintenance", action="store_true")
    p.add_argument("--version",     action="version", version=f"Version={VERSION}")
    return p.parse_args()


def main() -> None:
    """Program entry point: run the check and print the JSON result."""
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
            "dry_run": {"min_uid": MIN_UID, "min_rsa_bits": MIN_RSA_BITS, "include_system": INCLUDE_SYSTEM},
            "alerts": [], "duration_seconds": round(time.time() - _start_time, 2),
        }, indent=2))
        sys.exit(0)
    _lock_fd = acquire_lock()
    if _lock_fd is None:
        sys.exit(0)
    def _cleanup(signum, frame):
        """Release the lock and exit on signal."""
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
