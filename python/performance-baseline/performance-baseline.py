#!/usr/bin/env python3

###############################################################################
# performance-baseline.py                                                     #
# Captures a performance baseline: CPU usage, iowait%, memory percent, load   #
# averages, and network throughput. Compares with a saved baseline and alerts #
# on significant deviations (> DEVIATION_PCT%). Run once to establish the     #
# baseline; subsequent runs compare against it.                               #
# Author: Filcu Alexandru                                                     #
###############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Baseline storage
BASELINE_FILE = os.path.join(SCRIPT_DIR, "performance-baseline.json")

# Deviation threshold
DEVIATION_PCT   = 20.0   # alert when a metric deviates > this percent from baseline

# Sampling
SAMPLE_INTERVAL = 3      # seconds between /proc samples for CPU
TOP_PROCESSES   = 10     # number of top processes to include by RSS

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "performance-baseline.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "performance-baseline.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "performance-baseline.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "performance-baseline.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "performance-baseline"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "performance-baseline-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "performance-baseline-execution.log")
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



def collect_cpu_pct() -> Tuple[float, float]:
    """Collect CPU PCT."""
    def _read() -> Tuple[int, int, int]:
        """Read a file and return its text, or '' on error."""
        with open("/proc/stat") as f:
            parts = f.readline().split()
        total  = sum(int(x) for x in parts[1:])
        idle   = int(parts[4]) + int(parts[5])
        iowait = int(parts[5])
        return total, idle, iowait
    t1, i1, iw1 = _read()
    time.sleep(SAMPLE_INTERVAL)
    t2, i2, iw2 = _read()
    dt = t2 - t1
    if dt == 0:
        return 0.0, 0.0
    cpu_pct    = round((1.0 - (i2 - i1) / dt) * 100, 2)
    iowait_pct = round((iw2 - iw1) / dt * 100, 2)
    return cpu_pct, iowait_pct


def collect_memory_pct() -> float:
    """Collect memory PCT."""
    m: Dict[str, int] = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                p = line.split()
                if len(p) >= 2:
                    m[p[0].rstrip(":")] = int(p[1])
    except OSError:
        pass
    tot = m.get("MemTotal", 0)
    avail = m.get("MemAvailable", 0)
    return round((tot - avail) / tot * 100, 2) if tot else 0.0


def collect_load() -> Dict:
    """Collect load."""
    try:
        with open("/proc/loadavg") as f:
            p = f.read().split()
        return {"load_1": float(p[0]), "load_5": float(p[1]), "load_15": float(p[2])}
    except Exception:
        return {"load_1": 0.0, "load_5": 0.0, "load_15": 0.0}


def collect_network_mbps() -> Dict:
    """Collect network MBPS."""
    ifaces = []
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if ":" in line:
                    name = line.split(":")[0].strip()
                    if name and name != "lo":
                        ifaces.append(name)
    except OSError:
        pass
    if not ifaces:
        return {"rx_mbps": 0.0, "tx_mbps": 0.0}
    iface = ifaces[0]
    def _read_bytes() -> Tuple[int, int]:
        """Read and return the file's contents as bytes."""
        try:
            with open("/proc/net/dev") as f:
                for line in f:
                    if line.strip().startswith(iface + ":"):
                        p = line.strip().split()
                        return int(p[1]), int(p[9])
        except Exception:
            pass
        return 0, 0
    rx1, tx1 = _read_bytes()
    time.sleep(1)
    rx2, tx2 = _read_bytes()
    factor   = 8.0 / 1_000_000
    return {"interface": iface,
            "rx_mbps": round(max(0, rx2 - rx1) * factor, 2),
            "tx_mbps": round(max(0, tx2 - tx1) * factor, 2)}


def collect_top_procs() -> List[Dict]:
    """Collect top procs."""
    procs = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/comm") as f:
                comm = f.read().strip()
            with open(f"/proc/{entry}/stat") as f:
                raw = f.read()
            comm_end = raw.rfind(")")
            fields   = raw[comm_end + 2:].split()
            rss_mb   = round(int(fields[21]) * 4096 / 1048576, 2)
            procs.append({"pid": int(entry), "name": comm, "rss_mb": rss_mb})
        except (OSError, IndexError, ValueError):
            pass
    return sorted(procs, key=lambda p: -p["rss_mb"])[:TOP_PROCESSES]


def load_baseline() -> Optional[Dict]:
    """Load the performance baseline from disk."""
    try:
        with open(BASELINE_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def save_baseline(metrics: Dict) -> None:
    """Write the performance baseline to disk."""
    try:
        with open(BASELINE_FILE, "w") as f:
            json.dump(metrics, f, indent=2)
    except OSError:
        pass


def check_deviation(metric: str, current: float, baseline: float) -> Optional[str]:
    """Compare current metrics against the baseline."""
    if baseline == 0:
        return None
    deviation = abs(current - baseline) / baseline * 100
    if deviation > DEVIATION_PCT:
        direction = "up" if current > baseline else "down"
        return (f"{metric}: {current} vs baseline {baseline} "
                f"({deviation:.1f}% {direction}, threshold {DEVIATION_PCT}%)")
    return None


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    cpu_pct, iowait_pct = collect_cpu_pct()
    mem_pct  = collect_memory_pct()
    load     = collect_load()
    net      = collect_network_mbps()
    procs    = collect_top_procs()
    current  = {"timestamp": _now_iso(),
        "cpu_percent":     cpu_pct,
        "iowait_percent":  iowait_pct,
        "memory_percent":  mem_pct,
        "load_1min":       load["load_1"],
        "network_rx_mbps": net["rx_mbps"],
        "network_tx_mbps": net["tx_mbps"]}
    baseline = load_baseline()
    alerts   = []
    if baseline:
        for metric, key in (("CPU%", "cpu_percent"), ("Memory%", "memory_percent"),
                            ("IOWait%", "iowait_percent"), ("Load1", "load_1min")):
            a = check_deviation(metric, current.get(key, 0), baseline.get(key, 0))
            if a:
                alerts.append(a)
    save_baseline(current)
    return {
        "current":       current,
        "baseline":      baseline,
        "has_baseline":  baseline is not None,
        "top_processes": procs,
        "deviations":    alerts,
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
            "dry_run": {"baseline_file": BASELINE_FILE, "deviation_pct": DEVIATION_PCT, "has_baseline": os.path.isfile(BASELINE_FILE), "maintenance": is_maintenance(), "current_status": get_status()},
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
