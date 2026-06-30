#!/usr/bin/env python3

######################################################################
# process-monitor.py                                                 #
# Monitors configured processes for: not running, zombie state (Z),  #
# D-state hang (uninterruptible sleep), and RSS memory growth across #
# MEMORY_HISTORY samples. Reads /proc directly. Per-process status   #
# tracking with aggregated alert and individual recovery emails.     #
# Author: Filcu Alexandru                                            #
######################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Processes to monitor (binary names matched against /proc/*/comm)
PROCESSES = ["nginx", "sshd"]

# Thresholds
MEMORY_GROWTH_MB = 50.0  # alert when RSS grows more than this per sample window
MEMORY_HISTORY   = 5     # number of RSS samples to keep per process

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "process-monitor.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "process-monitor.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "process-monitor.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "process-monitor.email.state")

MEMORY_HISTORY_FILE = os.path.join(SCRIPT_DIR, "process-monitor.mem-history.json")

# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "process-monitor"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "process-monitor-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "process-monitor-execution.log")
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



def get_alerted() -> List[str]:
    try:
        with open(STATUS_FILE) as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except Exception:
        return []


def is_in_alert(name: str) -> bool:
    return name in get_alerted()


def add_alert(name: str) -> None:
    alerted = get_alerted()
    if name not in alerted:
        alerted.append(name)
        try:
            with open(STATUS_FILE, "w") as f:
                json.dump(alerted, f)
        except OSError:
            pass


def remove_alert(name: str) -> None:
    alerted = [x for x in get_alerted() if x != name]
    try:
        with open(STATUS_FILE, "w") as f:
            json.dump(alerted, f)
    except OSError:
        pass


def send_proc_recovery(name: str) -> None:
    if not ALERT_EMAIL:
        return
    _send_mail(f"Process recovery on {resolve_hostname()}",
               f"{name} is running normally again on {resolve_hostname()}.")
    log.warning("RECOVERY EMAIL sent for %s to %s", name, ALERT_EMAIL)


def load_mem_history() -> Dict[str, List[float]]:
    try:
        with open(MEMORY_HISTORY_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def update_mem_history(history: Dict, name: str, rss_mb: float) -> None:
    history.setdefault(name, []).append(rss_mb)
    history[name] = history[name][-MEMORY_HISTORY:]
    try:
        with open(MEMORY_HISTORY_FILE, "w") as f:
            json.dump(history, f)
    except OSError:
        pass


def find_pids(name: str) -> List[int]:
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/comm") as f:
                if f.read().strip() == name:
                    pids.append(int(entry))
        except OSError:
            pass
    return pids


def read_proc_stat(pid: int) -> Optional[Dict]:
    try:
        with open(f"/proc/{pid}/stat") as f:
            raw = f.read()
        comm_end = raw.rfind(")")
        fields   = raw[comm_end + 2:].split()
        state    = fields[0]
        rss_mb   = round(int(fields[21]) * 4096 / 1048576, 2)
        return {"state": state, "rss_mb": rss_mb}
    except (OSError, IndexError, ValueError):
        return None


def collect_process(name: str, mem_history: Dict) -> Dict:
    pids = find_pids(name)
    if not pids:
        return {"name": name, "running": False, "pids": [], "issues": ["not_running"]}
    issues = []; stats = []
    for pid in pids:
        stat = read_proc_stat(pid)
        if stat is None:
            continue
        stats.append({"pid": pid, **stat})
        if stat["state"] == "Z":
            issues.append(f"zombie pid={pid}")
        if stat["state"] == "D":
            issues.append(f"d_state pid={pid}")
    total_rss = sum(s["rss_mb"] for s in stats)
    update_mem_history(mem_history, name, total_rss)
    samples = mem_history.get(name, [])
    if len(samples) >= MEMORY_HISTORY:
        growth = samples[-1] - samples[0]
        if growth > MEMORY_GROWTH_MB:
            issues.append(f"memory_growth {growth:.1f} MB over {MEMORY_HISTORY} samples "
                          f"(current {total_rss:.1f} MB)")
    return {"name": name, "running": True, "pids": pids, "pid_count": len(pids),
            "total_rss_mb": total_rss, "rss_history_mb": samples, "issues": issues}


def _collect_all() -> Tuple[Dict, List[str]]:
    mem_history  = load_mem_history()
    proc_results = [collect_process(name, mem_history) for name in PROCESSES]
    newly_alerted = []; newly_recovered = []; all_alerts = []
    for proc in proc_results:
        if proc.get("issues"):
            issues_str = ", ".join(proc["issues"])
            all_alerts.append(f"{proc['name']}: {issues_str}")
            if not is_in_alert(proc["name"]):
                newly_alerted.append(proc["name"])
                add_alert(proc["name"])
        else:
            if is_in_alert(proc["name"]):
                newly_recovered.append(proc["name"])
                remove_alert(proc["name"])
    if newly_alerted:
        alert(chr(10).join(a for a in all_alerts if a.split(":")[0] in newly_alerted))
    for name in newly_recovered:
        send_proc_recovery(name)
    return {"processes": proc_results, "alerted": get_alerted(),
            "newly_alerted": newly_alerted, "newly_recovered": newly_recovered}, all_alerts



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
            "dry_run": {"processes": PROCESSES, "memory_growth_mb": MEMORY_GROWTH_MB, "currently_alerted": get_alerted(), "maintenance": is_maintenance()},
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
