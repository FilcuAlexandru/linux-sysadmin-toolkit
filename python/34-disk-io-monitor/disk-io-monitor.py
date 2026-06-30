#!/usr/bin/env python3

########################################################################
# disk-io-monitor.py                                                   #
# Takes two /proc/diskstats samples SAMPLE_INTERVAL apart.             #
# Computes read/write throughput in kB/s per whole disk.               #
# Emits JSON; alerts when a device exceeds IO_THRESHOLD_KBPS.          #
# Author: Filcu Alexandru                                              #
########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Thresholds
IO_THRESHOLD_KBPS = 102400.0   # alert when read+write throughput exceeds this (kB/s)
SAMPLE_INTERVAL   = 2          # seconds between /proc/diskstats samples

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "disk-io-monitor.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "disk-io-monitor.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "disk-io-monitor.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "disk-io-monitor.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "disk-io-monitor"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "disk-io-monitor-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "disk-io-monitor-execution.log")
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
    for d in os.environ.get("PATH", "/usr/bin:/bin").split(os.pathsep):
        if os.path.isfile(os.path.join(d, binname)) and os.access(os.path.join(d, binname), os.X_OK):
            return True
    return False


def diskstats() -> Dict[str, Tuple[int, int]]:
    res = {}
    for line in _read_file("/proc/diskstats").splitlines():
        p = line.split()
        if len(p) < 14:
            continue
        name = p[2]
        try:
            res[name] = (int(p[5]), int(p[9]))  # sectors read, sectors written
        except ValueError:
            continue
    return res


def _is_partition(name: str) -> bool:
    for pref in ("sd", "vd", "hd"):
        if name.startswith(pref) and name[len(pref):].isdigit():
            return True
    if name.startswith("nvme") and "p" in name:
        return True
    return False


def evaluate() -> Tuple[Dict, List[str]]:
    a = diskstats()
    time.sleep(SAMPLE_INTERVAL)
    b = diskstats()
    devs, alerts = [], []
    for name in sorted(set(a) & set(b)):
        if _is_partition(name) or name.startswith(("loop", "ram")):
            continue
        rd = (b[name][0] - a[name][0]) * 512 / 1024 / SAMPLE_INTERVAL
        wr = (b[name][1] - a[name][1]) * 512 / 1024 / SAMPLE_INTERVAL
        tot = rd + wr
        devs.append({"device": name, "read_kbps": round(rd, 1), "write_kbps": round(wr, 1)})
        if tot > IO_THRESHOLD_KBPS:
            alerts.append(f"High disk I/O on {name}: {round(tot, 1)} kB/s")
    return {"devices": devs, "threshold_kbps": IO_THRESHOLD_KBPS}, alerts


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=SCRIPT_NAME + " — see README.")
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
            "dry_run": {"threshold_kbps": IO_THRESHOLD_KBPS, "sample_interval": SAMPLE_INTERVAL,
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
