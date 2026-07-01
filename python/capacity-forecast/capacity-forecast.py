#!/usr/bin/env python3

##########################################################################
# capacity-forecast.py                                                   #
# Records disk usage history and fits a linear trend per filesystem.     #
# Projects days until each filesystem fills.                             #
# Emits JSON; alerts when projected time-to-full is below FORECAST_DAYS. #
# Author: Filcu Alexandru                                                #
##########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Thresholds
FORECAST_DAYS  = 14.0   # alert when projected time-to-full is below this many days
HISTORY_POINTS = 30     # number of samples retained per filesystem

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "capacity-forecast.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "capacity-forecast.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "capacity-forecast.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "capacity-forecast.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "capacity-forecast"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "capacity-forecast-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "capacity-forecast-execution.log")
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


def _read_file(path: str) -> str:
    """Best-effort text read; returns '' on any error."""
    try:
        with open(path) as f:
            return f.read()
    except Exception:
        return ""


def _run(cmd: List[str], timeout: int = 15) -> str:
    """Best-effort command runner; returns stdout or '' on any error."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout, check=False).stdout
    except Exception:
        return ""


def _have(binname: str) -> bool:
    """Return True if a binary is available on PATH."""
    for d in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep):
        if os.path.isfile(os.path.join(d, binname)) and os.access(os.path.join(d, binname), os.X_OK):
            return True
    return False


def collect_usage() -> Dict[str, Dict[str, int]]:
    """Collect usage."""
    out = _run(["df", "-P", "--block-size=1"])
    res = {}
    for line in out.splitlines()[1:]:
        p = line.split()
        if len(p) < 6:
            continue
        fs, tot, used, _avail, _pc, mnt = p[:6]
        if fs.startswith(("tmpfs", "devtmpfs", "udev", "overlay", "proc", "sysfs", "cgroup")):
            continue
        try:
            res[mnt] = {"used": int(used), "total": int(tot)}
        except ValueError:
            continue
    return res


def _slope(pts: List[List[float]]) -> float:
    """Return the least-squares slope of the points."""
    n = len(pts)
    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sxx = sum(p[0] * p[0] for p in pts)
    sxy = sum(p[0] * p[1] for p in pts)
    d = n * sxx - sx * sx
    return (n * sxy - sx * sy) / d if d else 0.0


def evaluate() -> Tuple[Dict, List[str]]:
    """Collect the data and return the (data, alerts) tuple."""
    hist_path = os.path.join(SCRIPT_DIR, SCRIPT_NAME + ".history.json")
    now = time.time()
    cur = collect_usage()
    try:
        with open(hist_path) as f:
            hist = json.load(f)
    except Exception:
        hist = {}
    alerts, forecasts = [], []
    for mnt, info in cur.items():
        pts = hist.get(mnt, [])
        pts.append([now, info["used"]])
        pts = pts[-HISTORY_POINTS:]
        hist[mnt] = pts
        eta = None
        if len(pts) >= 3:
            slope = _slope(pts)  # bytes/sec
            if slope > 0:
                free = info["total"] - info["used"]
                eta = round(free / slope / 86400, 1)
                forecasts.append({"mount": mnt, "eta_days": eta})
                if eta < FORECAST_DAYS:
                    alerts.append(f"{mnt} projected full in {eta} days")
        if eta is None:
            forecasts.append({"mount": mnt, "eta_days": None})
    try:
        with open(hist_path, "w") as f:
            json.dump(hist, f)
    except OSError:
        pass
    return {"forecasts": forecasts, "forecast_days": FORECAST_DAYS,
            "samples": {m: len(p) for m, p in hist.items()}}, alerts


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments."""
    p = argparse.ArgumentParser(description=SCRIPT_NAME + " — see README.")
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
            "dry_run": {"forecast_days": FORECAST_DAYS, "history_points": HISTORY_POINTS,
                        "running_as_root": (os.geteuid() == 0),
                        "maintenance": is_maintenance(),
                        "current_status": get_status(),
                        "last_email": last_email_age()},
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
        data, alerts   = evaluate()
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
