#!/usr/bin/env python3

############################################################################
# disk-trend-analyzer.py                                                   #
# Reads disk usage history from a JSON file, runs per-filesystem linear    #
# regression (pure Python stdlib), and estimates when each filesystem will #
# reach 100%. Appends the current df snapshot to history on every run.     #
# Alerts when ETA <= ALERT_DAYS or current usage > DISK_THRESHOLD.         #
# Author: Filcu Alexandru                                                  #
############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# History
HISTORY_FILE = os.path.join(SCRIPT_DIR, "disk-trend-history.json")
MAX_HISTORY  = 720   # maximum data points kept per mount (720 x 5min = 2.5d)

# Thresholds
ALERT_DAYS     = 7     # alert when filesystem will fill within this many days
DISK_THRESHOLD = 90.0  # also alert when current usage exceeds this percent

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "disk-trend-analyzer.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "disk-trend-analyzer"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "disk-trend-analyzer-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "disk-trend-analyzer-execution.log")
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



def collect_snapshot() -> List[Dict]:
    try:
        out = subprocess.run(["df", "-P", "--block-size=1"],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return []
    ts = _now_iso()
    points = []
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 6:
            continue
        fs, tot_b, used_b, _, _, mount = parts
        if fs.startswith(("tmpfs", "devtmpfs", "udev", "sysfs", "proc", "cgroup")):
            continue
        try:
            tot  = int(tot_b)
            used = int(used_b)
            points.append({"timestamp": ts, "mount": mount,
                "total_gb":  round(tot  / 1073741824, 2),
                "used_gb":   round(used / 1073741824, 2),
                "percent":   round(used / tot * 100, 2) if tot else 0.0})
        except ValueError:
            continue
    return points


def load_history() -> List[Dict]:
    try:
        with open(HISTORY_FILE) as f:
            return json.load(f)
    except Exception:
        return []


def append_history(history: List[Dict], new_points: List[Dict]) -> List[Dict]:
    history.extend(new_points)
    by_mount: Dict[str, List[Dict]] = {}
    for p in history:
        by_mount.setdefault(p["mount"], []).append(p)
    result = []
    for pts in by_mount.values():
        result.extend(pts[-MAX_HISTORY:])
    try:
        with open(HISTORY_FILE, "w") as f:
            json.dump(result, f)
    except OSError:
        pass
    return result


def linear_regression(xs: List[float], ys: List[float]) -> Tuple[float, float]:
    n = len(xs)
    if n < 2:
        return 0.0, ys[0] if ys else 0.0
    sx  = sum(xs); sy = sum(ys)
    sxy = sum(x * y for x, y in zip(xs, ys))
    sxx = sum(x * x for x in xs)
    denom = n * sxx - sx * sx
    if denom == 0:
        return 0.0, sy / n
    slope = (n * sxy - sx * sy) / denom
    return slope, (sy - slope * sx) / n


def days_until_full(slope: float, current_pct: float) -> Optional[float]:
    if slope <= 0:
        return None
    return round((100.0 - current_pct) / slope, 1)


def analyze_trends(history: List[Dict]) -> List[Dict]:
    by_mount: Dict[str, List[Dict]] = {}
    for p in history:
        by_mount.setdefault(p["mount"], []).append(p)
    results = []
    for mount, pts in sorted(by_mount.items()):
        if len(pts) < 2:
            continue
        try:
            t0 = datetime.datetime.strptime(pts[0]["timestamp"], "%Y-%m-%dT%H:%M:%SZ"
                ).replace(tzinfo=datetime.timezone.utc).timestamp()
            xs = [(datetime.datetime.strptime(p["timestamp"], "%Y-%m-%dT%H:%M:%SZ"
                  ).replace(tzinfo=datetime.timezone.utc).timestamp() - t0) / 86400
                  for p in pts]
            ys    = [p["percent"] for p in pts]
            slope, _ = linear_regression(xs, ys)
            cur   = pts[-1]
            eta   = days_until_full(slope, cur["percent"])
            results.append({
                "mount":             mount,
                "current_percent":   cur["percent"],
                "current_used_gb":   cur["used_gb"],
                "current_total_gb":  cur["total_gb"],
                "trend_pct_per_day": round(slope, 4),
                "data_points":       len(pts),
                "days_until_full":   eta,
                "eta_date": (datetime.datetime.now(datetime.timezone.utc) +
                             datetime.timedelta(days=eta)).strftime("%Y-%m-%d")
                             if eta is not None else None,
                "trend_label": (
                    "critical" if eta is not None and eta <= ALERT_DAYS else
                    "warning"  if eta is not None and eta <= ALERT_DAYS * 3 else
                    "stable"   if slope <= 0 else "ok"),
            })
        except Exception:
            continue
    return results


def _collect_all() -> Tuple[Dict, List[str]]:
    snap    = collect_snapshot()
    history = append_history(load_history(), snap)
    trends  = analyze_trends(history)
    alerts  = []
    for t in trends:
        if t["current_percent"] > DISK_THRESHOLD:
            alerts.append(f"Disk {t['mount']} at {t['current_percent']}% "
                          f"(threshold {DISK_THRESHOLD}%)")
        if t["days_until_full"] is not None and t["days_until_full"] <= ALERT_DAYS:
            alerts.append(f"Disk {t['mount']} full in {t['days_until_full']} days "
                          f"(by {t['eta_date']}), +{t['trend_pct_per_day']}%/day")
    return {"trends": trends, "history_points": len(history),
            "alert_days": ALERT_DAYS, "disk_threshold": DISK_THRESHOLD}, alerts



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
            "dry_run": {"history_file": HISTORY_FILE, "history_points": len(load_history()), "alert_days": ALERT_DAYS, "disk_threshold": DISK_THRESHOLD, "maintenance": is_maintenance(), "current_status": get_status()},
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
