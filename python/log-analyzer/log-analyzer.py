#!/usr/bin/env python3

#########################################################################
# log-analyzer.py                                                       #
# Parses syslog/journalctl output, counts log levels, extracts the most #
# frequent error patterns (numbers and IPs normalised to placeholders), #
# builds an hourly heatmap, and alerts on spikes. Supports any log file #
# path or journalctl as source.                                         #
# Author: Filcu Alexandru                                               #
#########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, re as _re_log
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Log source
LOG_FILE     = ""                   # path to log file; empty = use journalctl
LINES        = 10000                # max lines to analyze per run
WINDOW_HOURS = 24                   # hours to look back when using journalctl
TOP_PATTERNS = 20                   # number of top error patterns to report

# Alert threshold
ERROR_SPIKE_MULTIPLIER = 3.0        # alert when any hour > avg * this factor

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "log-analyzer.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "log-analyzer.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "log-analyzer.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "log-analyzer.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "log-analyzer"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "log-analyzer-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "log-analyzer-execution.log")
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



def collect_lines() -> List[str]:
    """Collect lines."""
    if LOG_FILE and os.path.isfile(LOG_FILE):
        try:
            with open(LOG_FILE) as f:
                return [l.rstrip() for l in f.readlines()[-LINES:]]
        except (OSError, PermissionError):
            return []
    since = (datetime.datetime.now() - datetime.timedelta(hours=WINDOW_HOURS)
             ).strftime("%Y-%m-%d %H:%M:%S")
    try:
        out = subprocess.run(
            ["journalctl", f"--since={since}", "--no-pager", "-q", "-n", str(LINES)],
            capture_output=True, text=True, timeout=30).stdout
        return out.splitlines()
    except Exception:
        return []


def count_levels(lines: List[str]) -> Dict[str, int]:
    """Count levels."""
    counts = {"DEBUG": 0, "INFO": 0, "WARNING": 0, "ERROR": 0, "CRITICAL": 0}
    for line in lines:
        upper = line.upper()
        for level in counts:
            if level in upper:
                counts[level] += 1; break
    return counts


def extract_patterns(lines: List[str]) -> List[Dict]:
    """Extract patterns."""
    normalised: Dict[str, int] = {}
    for line in lines:
        pat = _re_log.sub(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", "<IP>", line)
        pat = _re_log.sub(r"\b\d+\b", "<N>", pat)
        pat = _re_log.sub(r"\b[0-9a-fA-F]{8,}\b", "<HEX>", pat)
        pat = pat.strip()
        if pat:
            normalised[pat] = normalised.get(pat, 0) + 1
    return [{"pattern": k, "count": v}
            for k, v in sorted(normalised.items(), key=lambda x: -x[1])[:TOP_PATTERNS]]


def build_hourly_map(lines: List[str]) -> Dict[str, int]:
    """Build an hourly histogram of events."""
    counts = {str(h).zfill(2): 0 for h in range(24)}
    for line in lines:
        m = _re_log.search(r"\b(\d{2}):\d{2}:\d{2}\b", line)
        if m and m.group(1) in counts:
            counts[m.group(1)] += 1
    return counts


def detect_spike(hourly: Dict[str, int]) -> Optional[Dict]:
    """Detect a spike in the log line counts."""
    values = list(hourly.values())
    if not values:
        return None
    avg = sum(values) / len(values)
    if avg == 0:
        return None
    peak_hour = max(hourly, key=hourly.get)
    peak_val  = hourly[peak_hour]
    if peak_val > avg * ERROR_SPIKE_MULTIPLIER:
        return {"hour": peak_hour, "count": peak_val,
                "average": round(avg, 1),
                "multiplier": round(peak_val / avg, 1)}
    return None


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    lines    = collect_lines()
    levels   = count_levels(lines)
    patterns = extract_patterns(lines)
    hourly   = build_hourly_map(lines)
    spike    = detect_spike(hourly)
    alerts   = []
    if spike:
        alerts.append(f"Error spike at hour {spike['hour']}: "
                      f"{spike['count']} lines ({spike['multiplier']}x average)")
    return {
        "source":         LOG_FILE or "journalctl",
        "lines_analyzed": len(lines),
        "window_hours":   WINDOW_HOURS,
        "level_counts":   levels,
        "top_patterns":   patterns,
        "hourly_heatmap": hourly,
        "spike":          spike,
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
            "dry_run": {"log_file": LOG_FILE or "journalctl", "lines": LINES, "window_hours": WINDOW_HOURS, "journalctl_ok": subprocess.run(["which","journalctl"],capture_output=True).returncode==0, "maintenance": is_maintenance(), "current_status": get_status()},
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
