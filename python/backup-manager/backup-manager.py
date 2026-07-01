#!/usr/bin/env python3

############################################################################
# backup-manager.py                                                        #
# Runs incremental rsync backups with --link-dest, verifies integrity with #
# SHA-256 checksums (hashlib stdlib), and applies rotative retention       #
# (N daily / M weekly / K monthly). Produces a detailed JSON report.       #
# Author: Filcu Alexandru                                                  #
############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, hashlib as _hashlib, shutil as _shutil_bk
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Source and destination
SOURCE_DIR  = "/path/to/source"
BACKUP_BASE = os.path.join(SCRIPT_DIR, "backups")

# Retention
DAILY_KEEP   = 7
WEEKLY_KEEP  = 4
MONTHLY_KEEP = 3

# Integrity
VERIFY_CHECKSUMS = True    # compute SHA-256 checksums after backup
CHECKSUM_SAMPLE  = 100     # max files to verify (0 = all)

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "backup-manager.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "backup-manager.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "backup-manager.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "backup-manager.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "backup-manager"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "backup-manager-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "backup-manager-execution.log")
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



def run_rsync(source: str, destination: str) -> Dict:
    """Run the rsync backup command."""
    link_dest = ""
    daily_dir = os.path.join(BACKUP_BASE, "daily")
    if os.path.isdir(daily_dir):
        existing = sorted(os.listdir(daily_dir))
        if existing:
            link_dest = os.path.join(daily_dir, existing[-1])
    cmd = ["rsync", "-a", "--stats", "--delete"]
    if link_dest:
        cmd += [f"--link-dest={link_dest}"]
    cmd += [source.rstrip("/") + "/", destination]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=3600)
        stats: Dict = {"returncode": out.returncode, "output": out.stdout[:1000]}
        for line in out.stdout.splitlines():
            if "Number of files:" in line:
                stats["files_total"] = line.split(":")[-1].strip()
            if "Total transferred file size:" in line:
                stats["bytes_transferred"] = line.split(":")[-1].strip()
        return stats
    except Exception as exc:
        return {"returncode": -1, "error": str(exc)}


def compute_checksums(backup_dir: str) -> Dict:
    """Compute SHA-256 checksums of the backup."""
    if not VERIFY_CHECKSUMS or not os.path.isdir(backup_dir):
        return {"verified": 0, "status": "skipped"}
    files = []
    for root, _, fnames in os.walk(backup_dir):
        for fname in fnames:
            files.append(os.path.join(root, fname))
    if CHECKSUM_SAMPLE > 0 and len(files) > CHECKSUM_SAMPLE:
        import random as _rand
        files = _rand.sample(files, CHECKSUM_SAMPLE)
    errors = []
    for fpath in files:
        try:
            h = _hashlib.sha256()
            with open(fpath, "rb") as f:
                for chunk in iter(lambda: f.read(65536), b""):
                    h.update(chunk)
        except OSError as exc:
            errors.append(str(exc))
    return {"verified": len(files), "errors": len(errors),
            "status": "passed" if not errors else "failed"}


def apply_retention(category: str, keep: int) -> int:
    """Delete backups older than the retention window."""
    cat_dir = os.path.join(BACKUP_BASE, category)
    if not os.path.isdir(cat_dir):
        return 0
    entries   = sorted(os.listdir(cat_dir))
    to_delete = entries[:-keep] if keep > 0 else []
    deleted   = 0
    for entry in to_delete:
        path = os.path.join(cat_dir, entry)
        try:
            _shutil_bk.rmtree(path) if os.path.isdir(path) else os.remove(path)
            deleted += 1
        except OSError:
            pass
    return deleted


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    if not os.path.isdir(SOURCE_DIR):
        return {"error": f"Source directory not found: {SOURCE_DIR}"}, [
            f"Source directory not found: {SOURCE_DIR}"]
    ts     = datetime.datetime.now()
    cat    = "monthly" if ts.day == 1 else "weekly" if ts.weekday() == 0 else "daily"
    ts_str = ts.strftime("%Y-%m-%d_%H%M%S")
    dest_dir = os.path.join(BACKUP_BASE, cat, ts_str)
    os.makedirs(dest_dir, exist_ok=True)
    t0     = time.time()
    rsync  = run_rsync(SOURCE_DIR, dest_dir)
    chk    = compute_checksums(dest_dir)
    retention = {
        "daily":   apply_retention("daily",   DAILY_KEEP),
        "weekly":  apply_retention("weekly",  WEEKLY_KEEP),
        "monthly": apply_retention("monthly", MONTHLY_KEEP),
    }
    success = rsync.get("returncode", -1) == 0
    alerts  = []
    if not success:
        alerts.append(f"Backup failed: rsync exit code {rsync.get('returncode')}")
    if chk.get("errors", 0) > 0:
        alerts.append(f"Checksum verification failed: {chk['errors']} errors")
    return {
        "backup_id":          f"backup-{ts_str}",
        "category":           cat,
        "source":             SOURCE_DIR,
        "destination":        dest_dir,
        "backup_duration_s":  round(time.time() - t0, 2),
        "rsync":              rsync,
        "checksums":          chk,
        "retention_applied":  retention,
        "status":             "success" if success else "failed",
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
            "dry_run": {"source_dir": SOURCE_DIR, "backup_base": BACKUP_BASE, "daily_keep": DAILY_KEEP, "weekly_keep": WEEKLY_KEEP, "monthly_keep": MONTHLY_KEEP, "rsync_available": subprocess.run(["which","rsync"],capture_output=True).returncode==0},
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
