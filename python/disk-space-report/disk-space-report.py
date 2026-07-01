#!/usr/bin/env python3

##########################################################################
# disk-space-report.py                                                   #
# Reports disk space usage for all real filesystems with current usage,  #
# a visual ASCII bar chart, trend data from disk-trend-history.json,     #
# and ETA-to-full where history is available. Alerts when any filesystem #
# exceeds DISK_THRESHOLD or has ETA <= 7 days.                           #
# Author: Filcu Alexandru                                                #
##########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Thresholds
DISK_THRESHOLD = 90.0   # alert when any filesystem exceeds this percent
WARN_THRESHOLD = 80.0   # warning level

# History (reads disk-trend-analyzer history if available)
HISTORY_FILE = os.path.join(SCRIPT_DIR, "disk-trend-history.json")

# ASCII bar width
BAR_WIDTH = 30

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "disk-space-report.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "disk-space-report.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "disk-space-report.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "disk-space-report.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "disk-space-report"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "disk-space-report-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "disk-space-report-execution.log")
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



def collect_disks() -> List[Dict]:
    """Collect disks."""
    try:
        out = subprocess.run(["df", "-P", "--block-size=1"],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return []
    disks = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        fs, tot_b, used_b, avail_b, _, mount = parts
        if fs.startswith(("tmpfs", "devtmpfs", "udev", "sysfs", "proc", "cgroup")):
            continue
        try:
            tot  = int(tot_b); used = int(used_b)
            pct  = round(used / tot * 100, 2) if tot else 0.0
            disks.append({"filesystem": fs, "mount": mount,
                "total_gb":     round(tot          / 1073741824, 2),
                "used_gb":      round(used         / 1073741824, 2),
                "available_gb": round(int(avail_b) / 1073741824, 2),
                "percent":      pct,
                "status":       "critical" if pct > DISK_THRESHOLD else
                                "warning"  if pct > WARN_THRESHOLD  else "ok"})
        except ValueError:
            continue
    return disks


def build_ascii_bar(percent: float, width: int = BAR_WIDTH) -> str:
    """Build ascii bar."""
    filled = max(0, min(width, round(percent / 100 * width)))
    return f"[{'#' * filled}{'.' * (width - filled)}] {percent:5.1f}%"


def load_trend_data() -> Dict[str, Dict]:
    """Load trend data."""
    try:
        with open(HISTORY_FILE) as f:
            history = json.load(f)
    except Exception:
        return {}
    by_mount: Dict[str, list] = {}
    for p in history:
        by_mount.setdefault(p["mount"], []).append(p)
    trends: Dict[str, Dict] = {}
    for mount, pts in by_mount.items():
        if len(pts) >= 2:
            p0 = pts[0]; pn = pts[-1]
            try:
                t0 = datetime.datetime.strptime(
                    p0["timestamp"], "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=datetime.timezone.utc).timestamp()
                tn = datetime.datetime.strptime(
                    pn["timestamp"], "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=datetime.timezone.utc).timestamp()
                elapsed_days = (tn - t0) / 86400
                if elapsed_days > 0:
                    slope = (pn["percent"] - p0["percent"]) / elapsed_days
                    trends[mount] = {"trend_pct_per_day": round(slope, 4),
                                     "data_points": len(pts)}
                    if slope > 0:
                        remaining = 100.0 - pn["percent"]
                        eta_days  = round(remaining / slope, 1)
                        trends[mount]["days_until_full"] = eta_days
                        trends[mount]["eta_date"] = (
                            datetime.datetime.now(datetime.timezone.utc) +
                            datetime.timedelta(days=eta_days)).strftime("%Y-%m-%d")
            except Exception:
                pass
    return trends


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    disks  = collect_disks()
    trends = load_trend_data()
    alerts = []
    for d in disks:
        t = trends.get(d["mount"], {})
        d["ascii_bar"] = build_ascii_bar(d["percent"])
        d["trend"]     = t
        if d["percent"] > DISK_THRESHOLD:
            alerts.append(f"Disk {d['mount']} at {d['percent']}% "
                          f"(threshold {DISK_THRESHOLD}%)")
        if t.get("days_until_full") and t["days_until_full"] <= 7:
            alerts.append(f"Disk {d['mount']} full in {t['days_until_full']} days "
                          f"(by {t.get('eta_date', '')})")
    return {
        "disks": disks,
        "summary": {
            "total_filesystems": len(disks),
            "critical": sum(1 for d in disks if d["status"] == "critical"),
            "warning":  sum(1 for d in disks if d["status"] == "warning"),
            "ok":       sum(1 for d in disks if d["status"] == "ok"),
        },
        "has_trend_data": bool(trends),
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
            "dry_run": {"disk_threshold": DISK_THRESHOLD, "warn_threshold": WARN_THRESHOLD, "history_available": os.path.isfile(HISTORY_FILE), "maintenance": is_maintenance()},
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
