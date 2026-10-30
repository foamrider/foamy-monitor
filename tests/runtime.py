#!/usr/bin/env python3
"""Load Foamy Monitor offscreen under both hosts (4.0.6 installed, 4.5 reference)
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, and fake hyprctl/brightness/FluxCast on a PATH without Omarchy's
scripts (tests/fakebin.py). Checks tests/qml/Runtime.qml, `qs ipc call
foamy.monitor status` answered by the leader, that brightness jobs never
overlapped, and that the teardown stopped FluxCast.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness;
FOAMY_HOST_40 / FOAMY_HOST_45 override the host shells."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN / "tests"))
import fakebin  # noqa: E402

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
if not (KIT / "preview/harness.py").exists():
    print(f"SKIP: foamy-kit harness not found at {KIT} (set FOAMY_KIT)")
    raise SystemExit(0)
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

CONFIG = '''local omarchy_monitor_scale = "auto"
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
'''


def ipc_status(run):
    by_id = Path(run.env["XDG_RUNTIME_DIR"]) / "quickshell/by-id"
    for _ in range(150):
        ids = [p.name for p in by_id.iterdir()] if by_id.is_dir() else []
        if ids and "FOAMY READY" in (run.base / "qs.log").read_text(errors="replace"):
            break
        time.sleep(0.1)
    else:
        return None
    result = subprocess.run(["qs", "ipc", "-i", ids[0], "call", "foamy.monitor", "status"], env=run.env,
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else None


def overlaps(path):
    events = [line.split() for line in path.read_text().splitlines()] if path.exists() else []
    depth, worst = 0, 0
    for kind, _ in sorted(events, key=lambda e: float(e[1])):
        depth += 1 if kind == "start" else -1
        worst = max(worst, depth)
    return worst, sum(1 for e in events if e[0] == "start")


def run(host, lang):
    shell = (PLUGIN / "tests/qml/Runtime.qml").read_text()
    r = harness.Run(host, shell, plugin=PLUGIN, language=lang, prefix=f"foamy-monitor-runtime-{host}-{lang}-")
    home = Path(r.env["HOME"])
    (home / ".config/hypr").mkdir(parents=True)
    (home / ".config/hypr/monitors.lua").write_text(CONFIG)
    fake = fakebin.write(r.base / "bin", count=3)
    calls = r.base / "calls.log"
    r.env.update(FOAMY_LANG=lang, FOAMY_HOLD_MS="500", PATH=f"{fake}:/usr/bin", FOAMY_CALLS=str(calls))
    log_path = r.base / "qs.log"
    process = subprocess.Popen(["qs", "-p", str(r.root), "--no-color"], env=r.env, stdout=log_path.open("w"),
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        status = ipc_status(r)
        process.wait(timeout=60)
    finally:
        if process.poll() is None:
            process.kill()
    log = log_path.read_text(errors="replace")
    result = next((line.split("FOAMY RESULT ", 1)[1] for line in log.splitlines() if "FOAMY RESULT" in line), "no result")
    failures = [line for line in log.splitlines() if "FOAMY FAIL" in line or any(m in line for m in harness.FAILURE_MARKERS)]
    try:
        leader = status is not None and json.loads(status).get("leader") is True
    except ValueError:
        leader = False
    depth, jobs = overlaps(Path(str(calls) + ".ddc"))
    text = calls.read_text() if calls.exists() else ""
    stopped = "fluxcast-signal" in text
    if depth != 1:
        failures.append(f"brightness jobs overlapped (max {depth} at once, {jobs} jobs)")
    if not stopped:
        failures.append("FluxCast was not signalled by the teardown")
    ok = "FOAMY DONE" in log and not failures and leader
    print(f"{'PASS' if ok else 'FAIL'} runtime {host} {lang}: {result}; ipc status from leader: {leader}; "
          f"{jobs} brightness jobs, max {depth} at once; FluxCast stopped: {stopped}")
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
        print(f"    log kept at {r.base}")
    elif not os.environ.get("FOAMY_KEEP"):
        r.cleanup()
    return ok


if __name__ == "__main__":
    cases = [("4.0", "en"), ("4.5", "en"), ("4.5", "no"), ("4.5", "ar")]
    if len(sys.argv) > 1:
        cases = [c for c in cases if c[0] in sys.argv[1:] or f"{c[0]}/{c[1]}" in sys.argv[1:]]
    results = [run(host, lang) for host, lang in cases]
    raise SystemExit(0 if all(results) else 1)
