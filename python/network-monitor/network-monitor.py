#!/usr/bin/env python3

##############################################################################
# network-monitor.py                                                         #
# Monitors per-interface network throughput (Mbit/s), error/drop deltas,     #
# and TCP/UDP connection state counts. Reads /proc/net/dev for byte counters #
# and /proc/net/tcp + /proc/net/tcp6 for connection states. Two samples      #
# SAMPLE_INTERVAL seconds apart compute throughput. Alerts per-metric.       #
# Author: Filcu Alexandru                                                    #
##############################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Interfaces
INTERFACES = []               # empty = auto-detect all non-loopback interfaces

# Thresholds
THROUGHPUT_THRESHOLD_MBPS = 100.0  # alert when RX or TX exceeds this
ERROR_THRESHOLD           = 100    # alert when error+drop delta exceeds this per sample
SAMPLE_INTERVAL           = 2      # seconds between /proc/net/dev reads
TCP_ESTABLISHED_THRESHOLD = 1000   # alert on high ESTABLISHED count
TCP_TIME_WAIT_THRESHOLD   = 500    # alert on high TIME_WAIT count

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "network-monitor.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "network-monitor.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "network-monitor.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "network-monitor.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "network-monitor"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "network-monitor-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "network-monitor-execution.log")
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



def get_interfaces() -> List[str]:
    """Return the list of network interfaces."""
    if INTERFACES:
        return list(INTERFACES)
    ifaces = []
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                stripped = line.strip()
                if ":" not in stripped:
                    continue
                name = stripped.split(":")[0].strip()
                if name and name != "lo":
                    ifaces.append(name)
    except OSError:
        pass
    return ifaces


def _read_iface_stats(iface: str) -> Optional[Tuple]:
    """Read the RX and TX statistics for an interface."""
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if line.strip().startswith(iface + ":"):
                    p = line.strip().split()
                    return (int(p[1]),  int(p[2]),  int(p[3]),  int(p[4]),
                            int(p[9]),  int(p[10]), int(p[11]), int(p[12]))
    except (OSError, IndexError, ValueError):
        pass
    return None


def collect_throughput(iface: str) -> Dict:
    """Collect throughput."""
    s1 = _read_iface_stats(iface)
    if s1 is None:
        return {"interface": iface, "available": False}
    time.sleep(SAMPLE_INTERVAL)
    s2 = _read_iface_stats(iface)
    if s2 is None:
        return {"interface": iface, "available": False}
    factor = 8.0 / (SAMPLE_INTERVAL * 1_000_000)
    return {"interface":   iface,
            "available":   True,
            "rx_mbps":     round(max(0, s2[0] - s1[0]) * factor, 2),
            "tx_mbps":     round(max(0, s2[4] - s1[4]) * factor, 2),
            "rx_errors":   max(0, s2[2] - s1[2]) + max(0, s2[3] - s1[3]),
            "tx_errors":   max(0, s2[6] - s1[6]) + max(0, s2[7] - s1[7]),
            "rx_pps":      max(0, s2[1] - s1[1]),
            "tx_pps":      max(0, s2[5] - s1[5]),
            "threshold_mbps": THROUGHPUT_THRESHOLD_MBPS}


def collect_connections() -> Dict:
    """Collect connections."""
    STATE_MAP = {
        "01": "ESTABLISHED", "02": "SYN_SENT",  "03": "SYN_RECV",
        "04": "FIN_WAIT1",   "05": "FIN_WAIT2", "06": "TIME_WAIT",
        "07": "CLOSE",       "08": "CLOSE_WAIT","09": "LAST_ACK",
        "0A": "LISTEN",      "0B": "CLOSING"}
    counts: Dict[str, int] = {}
    for pf in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(pf) as f:
                for line in f:
                    parts = line.split()
                    if len(parts) < 4 or parts[0] == "sl":
                        continue
                    state = STATE_MAP.get(parts[3].upper(), parts[3])
                    counts[state] = counts.get(state, 0) + 1
        except OSError:
            pass
    udp = 0
    for pf in ("/proc/net/udp", "/proc/net/udp6"):
        try:
            with open(pf) as f:
                udp += sum(1 for l in f if not l.startswith("  sl"))
        except OSError:
            pass
    return {"tcp": counts, "udp_sockets": udp}


def _collect_all() -> Tuple[Dict, List[str]]:
    """Collect all metrics and return the (data, alerts) tuple."""
    ifaces      = get_interfaces()
    iface_stats = [collect_throughput(iface) for iface in ifaces]
    connections = collect_connections()
    alerts      = []
    for s in iface_stats:
        if not s.get("available"):
            continue
        for direction, val in (("RX", s["rx_mbps"]), ("TX", s["tx_mbps"])):
            if val > THROUGHPUT_THRESHOLD_MBPS:
                alerts.append(f"Interface {s['interface']} {direction} {val} Mbit/s "
                               f"(threshold {THROUGHPUT_THRESHOLD_MBPS})")
        if s["rx_errors"] > ERROR_THRESHOLD:
            alerts.append(f"Interface {s['interface']} errors/drops {s['rx_errors']} "
                          f"in {SAMPLE_INTERVAL}s (threshold {ERROR_THRESHOLD})")
    tcp = connections.get("tcp", {})
    if tcp.get("ESTABLISHED", 0) > TCP_ESTABLISHED_THRESHOLD:
        alerts.append(f"TCP ESTABLISHED {tcp['ESTABLISHED']} "
                      f"(threshold {TCP_ESTABLISHED_THRESHOLD})")
    if tcp.get("TIME_WAIT", 0) > TCP_TIME_WAIT_THRESHOLD:
        alerts.append(f"TCP TIME_WAIT {tcp['TIME_WAIT']} "
                      f"(threshold {TCP_TIME_WAIT_THRESHOLD})")
    return {"interfaces": iface_stats, "connections": connections}, alerts



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
            "dry_run": {"interfaces_detected": get_interfaces(), "throughput_threshold": THROUGHPUT_THRESHOLD_MBPS, "sample_interval": SAMPLE_INTERVAL, "maintenance": is_maintenance(), "current_status": get_status()},
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
