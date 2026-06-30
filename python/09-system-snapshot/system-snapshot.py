#!/usr/bin/env python3

##########################################################################
# system-snapshot.py                                                     #
# Captures a complete system state snapshot: installed packages, running #
# services, open ports, local users, crontabs, and kernel parameters.    #
# Saves the snapshot as JSON and diffs it against the previous run to    #
# report exactly what changed on the system between two points in time.  #
# Author: Filcu Alexandru                                                #
##########################################################################

import os, sys, json, logging, datetime, fcntl, socket, subprocess
import time, signal, argparse, shutil as _shutil
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Snapshot storage
SNAPSHOT_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.current.json")
PREVIOUS_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.previous.json")

# What to capture
CAPTURE_PACKAGES = True
CAPTURE_SERVICES = True
CAPTURE_PORTS    = True
CAPTURE_USERS    = True
CAPTURE_CRONTABS = True
CAPTURE_SYSCTL   = True

# E-Mail
ALERT_EMAIL    = ""          # "ops@example.com" or space-separated list
EMAIL_INTERVAL = 3600        # seconds between alert emails

# Logging
LOG_RETENTION_DAYS = 14      # delete .log files older than this; 0 = keep forever

# Host
HOSTNAME_LABEL = ""          # override auto-detected hostname

# Maintenance
MAINTENANCE_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.maintenance")

# Locking
LOCK_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.lock")

# Status
STATUS_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.status")

# State
STATE_FILE = os.path.join(SCRIPT_DIR, "system-snapshot.email.state")


# Script logic below; no changes needed past this line.

VERSION     = "0.1"
SCRIPT_NAME = "system-snapshot"
_ERROR_LOG     = os.path.join(SCRIPT_DIR, "system-snapshot-error.log")
_EXECUTION_LOG = os.path.join(SCRIPT_DIR, "system-snapshot-execution.log")
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



def capture_packages() -> List[str]:
    for cmd in (["dpkg", "--get-selections"], ["rpm", "-qa"],
                ["apk", "list", "--installed"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if out.returncode == 0:
                return sorted(out.stdout.splitlines())
        except Exception:
            pass
    return []


def capture_services() -> Dict[str, str]:
    services: Dict[str, str] = {}
    try:
        out = subprocess.run(
            ["systemctl", "list-units", "--type=service",
             "--no-legend", "--no-pager", "--plain"],
            capture_output=True, text=True, timeout=15).stdout
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 4:
                services[p[0]] = p[3]
    except Exception:
        pass
    return services


def capture_ports() -> List[str]:
    ports = []
    try:
        out = subprocess.run(["ss", "-tlunp"],
                             capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines()[1:]:
            p = line.split()
            if len(p) >= 5:
                local = p[4]; port = local.rsplit(":", 1)[-1]; proto = p[0]
                if port.isdigit():
                    ports.append(f"{proto}:{port}")
    except Exception:
        pass
    return sorted(set(ports))


def capture_users() -> List[str]:
    users = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                p = line.strip().split(":")
                if len(p) >= 7 and p[6] not in (
                        "/sbin/nologin", "/bin/false", "/usr/sbin/nologin"):
                    users.append(f"{p[0]}:uid={p[2]}:shell={p[6]}")
    except OSError:
        pass
    return sorted(users)


def capture_crontabs() -> Dict[str, List[str]]:
    crontabs: Dict[str, List[str]] = {}
    files = []
    if os.path.isfile("/etc/crontab"):
        files.append("/etc/crontab")
    if os.path.isdir("/etc/cron.d"):
        try:
            _cd = os.listdir("/etc/cron.d")
        except OSError:
            _cd = []
        for f in _cd:
            files.append(os.path.join("/etc/cron.d", f))
    for cron_file in files:
        try:
            with open(cron_file) as f:
                lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
            if lines:
                crontabs[cron_file] = lines
        except OSError:
            pass
    spool = "/var/spool/cron/crontabs"
    if os.path.isdir(spool):
        try:
            _users = os.listdir(spool)
        except OSError:
            _users = []
        for user in _users:
            try:
                with open(os.path.join(spool, user)) as f:
                    lines = [l.strip() for l in f if l.strip() and not l.startswith("#")]
                if lines:
                    crontabs[f"user:{user}"] = lines
            except OSError:
                pass
    return crontabs


def capture_sysctl() -> Dict[str, str]:
    params: Dict[str, str] = {}
    for key in ("kernel.hostname", "net.ipv4.ip_forward",
                "net.ipv4.conf.all.accept_redirects",
                "kernel.randomize_va_space", "vm.swappiness"):
        try:
            out = subprocess.run(["sysctl", "-n", key],
                                 capture_output=True, text=True, timeout=5).stdout.strip()
            params[key] = out
        except Exception:
            pass
    return params


def build_snapshot() -> Dict:
    snap: Dict = {"timestamp": _now_iso(), "host": resolve_hostname()}
    if CAPTURE_PACKAGES:  snap["packages"]  = capture_packages()
    if CAPTURE_SERVICES:  snap["services"]  = capture_services()
    if CAPTURE_PORTS:     snap["ports"]     = capture_ports()
    if CAPTURE_USERS:     snap["users"]     = capture_users()
    if CAPTURE_CRONTABS:  snap["crontabs"]  = capture_crontabs()
    if CAPTURE_SYSCTL:    snap["sysctl"]    = capture_sysctl()
    return snap


def load_snapshot(path: str) -> Optional[Dict]:
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def diff_snapshots(prev: Dict, curr: Dict) -> Dict:
    diff: Dict = {}
    for section in ("packages", "ports", "users"):
        p = prev.get(section, []); c = curr.get(section, [])
        if isinstance(p, list) and isinstance(c, list):
            ps = set(p); cs = set(c)
            added = sorted(cs - ps); removed = sorted(ps - cs)
            if added or removed:
                diff[section] = {"added": added, "removed": removed}
    prev_svc = prev.get("services", {}); curr_svc = curr.get("services", {})
    svc_changes = {svc: {"from": prev_svc.get(svc, "absent"),
                          "to": curr_svc.get(svc, "absent")}
                   for svc in set(list(prev_svc) + list(curr_svc))
                   if prev_svc.get(svc, "absent") != curr_svc.get(svc, "absent")}
    if svc_changes:
        diff["services"] = svc_changes
    prev_cron = prev.get("crontabs", {}); curr_cron = curr.get("crontabs", {})
    if prev_cron != curr_cron:
        diff["crontabs"] = {
            "added_files":   [k for k in curr_cron if k not in prev_cron],
            "removed_files": [k for k in prev_cron if k not in curr_cron],
            "changed_files": [k for k in curr_cron
                              if k in prev_cron and curr_cron[k] != prev_cron[k]]}
    prev_sc = prev.get("sysctl", {}); curr_sc = curr.get("sysctl", {})
    sc_chg  = {k: {"from": prev_sc.get(k), "to": curr_sc.get(k)}
               for k in set(list(prev_sc) + list(curr_sc))
               if prev_sc.get(k) != curr_sc.get(k)}
    if sc_chg:
        diff["sysctl"] = sc_chg
    return diff


def _collect_all() -> Tuple[Dict, List[str]]:
    prev_snap = load_snapshot(SNAPSHOT_FILE)
    curr_snap = build_snapshot()
    if os.path.isfile(SNAPSHOT_FILE):
        _shutil.copy2(SNAPSHOT_FILE, PREVIOUS_FILE)
    with open(SNAPSHOT_FILE, "w") as f:
        json.dump(curr_snap, f, indent=2)
    diff   = diff_snapshots(prev_snap, curr_snap) if prev_snap else {}
    alerts = []
    if "users" in diff:
        for u in diff["users"].get("added",   []): alerts.append(f"New user added: {u}")
        for u in diff["users"].get("removed", []): alerts.append(f"User removed: {u}")
    if "ports" in diff:
        for p in diff["ports"].get("added", []): alerts.append(f"New listening port: {p}")
    if "crontabs" in diff:
        for f in diff["crontabs"].get("added_files",   []):
            alerts.append(f"New crontab: {f}")
        for f in diff["crontabs"].get("changed_files", []):
            alerts.append(f"Crontab changed: {f}")
    if alerts and should_send_email():
        _send_mail(f"System snapshot changes on {resolve_hostname()}", chr(10).join(alerts))
        mark_email_sent()
    return {
        "snapshot":     curr_snap,
        "diff":         diff,
        "has_previous": prev_snap is not None,
        "summary": {"packages": len(curr_snap.get("packages", [])),
            "services": len(curr_snap.get("services", {})),
            "ports":    len(curr_snap.get("ports",    [])),
            "users":    len(curr_snap.get("users",    [])),
            "changes":  len(diff)},
    }, alerts



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
            "dry_run": {"snapshot_file": SNAPSHOT_FILE, "previous_file": PREVIOUS_FILE, "capture_config": {"packages": CAPTURE_PACKAGES, "services": CAPTURE_SERVICES, "ports": CAPTURE_PORTS, "users": CAPTURE_USERS}, "has_previous": os.path.isfile(SNAPSHOT_FILE), "running_as_root": (os.geteuid() == 0), "unreadable_paths": [p for p in ("/etc/cron.d", "/var/spool/cron/crontabs") if os.path.exists(p) and not os.access(p, os.R_OK)]},
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
