#!/usr/bin/env python3

##########################################################################
# system-monitor.py                                                      #
# Collects CPU, memory, swap, disk, and network metrics in one run.      #
# Reads /proc directly for CPU/memory/swap/network; uses df -P for disk. #
# Two /proc/net/dev samples NETWORK_SAMPLE_INTERVAL seconds apart give   #
# throughput in Mbit/s. Alerts per-metric with individual thresholds.    #
# Author: Filcu Alexandru                                                #
##########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Thresholds
CPU_THRESHOLD       = 85.0   # alert when CPU usage exceeds this percent
MEMORY_THRESHOLD    = 90.0   # alert when memory usage exceeds this percent
SWAP_THRESHOLD      = 80.0   # alert when swap usage exceeds this percent
DISK_THRESHOLD      = 90.0   # alert when any filesystem exceeds this percent
LOAD_MULTIPLIER     = 1.5    # alert when 1-min load > cores * this value

# Network
NETWORK_INTERFACE       = "eth0"  # interface to measure throughput
NETWORK_THRESHOLD_MBPS  = 100.0   # alert when RX or TX exceeds this Mbit/s
NETWORK_SAMPLE_INTERVAL = 2       # seconds between /proc/net/dev reads

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "system-monitor.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "system-monitor.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "system-monitor.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "system-monitor.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "system-monitor"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "system-monitor-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "system-monitor-execution.log")
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



###############################################################################
# CPU collection.                                                             #
#   - _read_cpu_times : reads cumulative jiffies from /proc/stat.            #
#   - collect_cpu     : two samples 0.5s apart; computes usage percent,      #
#                       load averages, and core count.                       #
###############################################################################
def _read_cpu_times() -> Tuple[int, int]:
    with open("/proc/stat") as f:
        parts = f.readline().split()
    total = sum(int(x) for x in parts[1:])
    idle  = int(parts[4]) + int(parts[5])
    return total, idle


def collect_cpu() -> Dict:
    t1, i1 = _read_cpu_times()
    time.sleep(0.5)
    t2, i2 = _read_cpu_times()
    dt  = t2 - t1
    pct = round((1.0 - (i2 - i1) / dt) * 100, 2) if dt > 0 else 0.0
    try:
        with open("/proc/cpuinfo") as f:
            cores = sum(1 for l in f if l.startswith("processor"))
    except OSError:
        cores = 1
    try:
        with open("/proc/loadavg") as f:
            p = f.read().split()
        l1, l5, l15 = float(p[0]), float(p[1]), float(p[2])
    except OSError:
        l1 = l5 = l15 = 0.0
    return {"percent": pct, "load_1": l1, "load_5": l5, "load_15": l15,
            "cores": cores, "load_limit": round(cores * LOAD_MULTIPLIER, 2)}


###############################################################################
# Memory and swap collection.                                                 #
#   - _parse_meminfo : parses /proc/meminfo into a key->kB dict.             #
#   - collect_memory : computes used/total/available in GB and percent.      #
#   - collect_swap   : computes swap usage; sets has_swap=False when 0.      #
###############################################################################
def _parse_meminfo() -> Dict[str, int]:
    info: Dict[str, int] = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = int(parts[1])
    return info


def collect_memory() -> Dict:
    m     = _parse_meminfo()
    tot   = m.get("MemTotal", 0)
    avail = m.get("MemAvailable", m.get("MemFree", 0))
    used  = tot - avail
    return {"total_gb":     round(tot   / 1048576, 2),
            "used_gb":      round(used  / 1048576, 2),
            "available_gb": round(avail / 1048576, 2),
            "percent":      round(used / tot * 100, 2) if tot else 0.0}


def collect_swap() -> Dict:
    m    = _parse_meminfo()
    tot  = m.get("SwapTotal", 0)
    free = m.get("SwapFree",  0)
    used = tot - free
    return {"has_swap": tot > 0,
            "total_gb": round(tot  / 1048576, 2),
            "used_gb":  round(used / 1048576, 2),
            "percent":  round(used / tot * 100, 2) if tot else 0.0}


###############################################################################
# Disk usage collection.                                                      #
#   - collect_disks : runs df -P --block-size=1 and parses real filesystems. #
#                     Skips pseudo mounts (tmpfs, devtmpfs, etc.).           #
###############################################################################
def collect_disks() -> List[Dict]:
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
            tot  = int(tot_b)
            used = int(used_b)
            disks.append({"filesystem": fs, "mount": mount,
                "total_gb":     round(tot          / 1073741824, 2),
                "used_gb":      round(used         / 1073741824, 2),
                "available_gb": round(int(avail_b) / 1073741824, 2),
                "percent":      round(used / tot * 100, 2) if tot else 0.0})
        except ValueError:
            continue
    return disks


###############################################################################
# Network throughput collection.                                              #
#   - _iface_exists    : checks if NETWORK_INTERFACE is in /proc/net/dev.   #
#   - _read_iface_bytes: reads rx_bytes ($2) and tx_bytes ($10).             #
#   - collect_network  : two samples NETWORK_SAMPLE_INTERVAL apart;          #
#                        computes RX/TX in Mbit/s.                           #
###############################################################################
def _iface_exists(iface: str) -> bool:
    try:
        with open("/proc/net/dev") as f:
            return any(l.strip().startswith(iface + ":") for l in f)
    except OSError:
        return False


def _read_iface_bytes(iface: str) -> Tuple[int, int]:
    with open("/proc/net/dev") as f:
        for line in f:
            if line.strip().startswith(iface + ":"):
                p = line.strip().split()
                return int(p[1]), int(p[9])
    raise ValueError(f"Interface {iface} not found")


def collect_network() -> Dict:
    if not _iface_exists(NETWORK_INTERFACE):
        return {"interface": NETWORK_INTERFACE, "available": False}
    try:
        rx1, tx1 = _read_iface_bytes(NETWORK_INTERFACE)
        time.sleep(NETWORK_SAMPLE_INTERVAL)
        rx2, tx2 = _read_iface_bytes(NETWORK_INTERFACE)
        factor   = 8.0 / (NETWORK_SAMPLE_INTERVAL * 1_000_000)
        return {"interface": NETWORK_INTERFACE, "available": True,
                "rx_mbps": round(max(0, rx2 - rx1) * factor, 2),
                "tx_mbps": round(max(0, tx2 - tx1) * factor, 2),
                "threshold_mbps": NETWORK_THRESHOLD_MBPS}
    except Exception as exc:
        return {"interface": NETWORK_INTERFACE, "available": False, "error": str(exc)}


###############################################################################
# Alert evaluation and main collection entry point.                           #
###############################################################################
def _collect_all() -> Tuple[Dict, List[str]]:
    cpu   = collect_cpu()
    mem   = collect_memory()
    swap  = collect_swap()
    disks = collect_disks()
    net   = collect_network()
    alerts = []
    if cpu["percent"] > CPU_THRESHOLD:
        alerts.append(f"CPU at {cpu['percent']}% (threshold {CPU_THRESHOLD}%)")
    if cpu["load_1"] > cpu["load_limit"]:
        alerts.append(f"Load {cpu['load_1']} > limit {cpu['load_limit']}")
    if mem["percent"] > MEMORY_THRESHOLD:
        alerts.append(f"Memory at {mem['percent']}% ({mem['used_gb']}/{mem['total_gb']} GB)")
    if swap.get("has_swap") and swap["percent"] > SWAP_THRESHOLD:
        alerts.append(f"Swap at {swap['percent']}% ({swap['used_gb']}/{swap['total_gb']} GB)")
    for d in disks:
        if d["percent"] > DISK_THRESHOLD:
            alerts.append(f"Disk {d['mount']} at {d['percent']}% "
                          f"({d['used_gb']}/{d['total_gb']} GB)")
    if net.get("available"):
        for direction, val in (("RX", net["rx_mbps"]), ("TX", net["tx_mbps"])):
            if val > NETWORK_THRESHOLD_MBPS:
                alerts.append(f"Network {direction} {val} Mbit/s on {NETWORK_INTERFACE}")
    return {"cpu": cpu, "memory": mem, "swap": swap,
            "disks": disks, "network": net}, alerts



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
            "dry_run": {"cpu_threshold": CPU_THRESHOLD, "memory_threshold": MEMORY_THRESHOLD, "disk_threshold": DISK_THRESHOLD, "network_interface": NETWORK_INTERFACE, "maintenance": is_maintenance(), "current_status": get_status(), "last_email": last_email_age()},
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
