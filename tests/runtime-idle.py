#!/usr/bin/env python3
"""Measure what foamy-monitor runs while its popups are closed.

Loads Panel.qml N times (one per simulated monitor, as 4.5 does) in an
isolated offscreen Quickshell with the foamy-kit harness (temp HOME/XDG,
no Wayland/Hyprland variables) and fake hyprctl/brightness/gsettings on a
PATH that holds nothing else from Omarchy. After a warm-up it counts the
processes started and the CPU used by the shell and its children while every
popup stays closed.

  tests/runtime-idle.py [--plugin DIR] [--host 4.0|4.5] [--instances 3] [--seconds 30]
                        [--max-idle-spawns N]

Exits 1 when more than --max-idle-spawns processes start in the idle window
(the regression check; default 0).
"""
import argparse
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fakebin  # noqa: E402


def kit_preview(plugin):
    for candidate in (os.environ.get("FOAMY_KIT"), plugin.parent / "foamy-kit", HERE.parents[1] / "foamy-kit"):
        if candidate and (Path(candidate) / "preview/harness.py").is_file():
            return Path(candidate) / "preview"
    raise SystemExit("foamy-kit not found (set FOAMY_KIT)")


SHELL = '''import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "harness"
import "plugin" as Plugin

ShellRoot {
  id: shell
  Variants {
    model: Array.from({ length: Number(Quickshell.env("FOAMY_INSTANCES") || 1) }, function(_, i) { return i })
    delegate: FloatingWindow {
      id: barWindow
      required property var modelData
      implicitWidth: 160
      implicitHeight: 34
      property QtObject mockBar: MockBar { pluginId: "foamy.monitor"; moduleName: "foamy.monitor" }
      Plugin.Panel { bar: barWindow.mockBar; width: 40; height: 30 }
    }
  }
  Component.onCompleted: console.log("FOAMY READY")
}
'''

CONFIG = '''local omarchy_monitor_scale = "auto"
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
'''


def cpu_seconds(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    # utime, stime, cutime, cstime (fields 14-17; index 11-14 after the comm)
    return sum(int(v) for v in fields[11:15]) / os.sysconf("SC_CLK_TCK")


def calls(path):
    return path.read_text().splitlines() if path.exists() else []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plugin", default=str(HERE.parent))
    parser.add_argument("--host", default="4.5", choices=["4.0", "4.5"])
    parser.add_argument("--instances", type=int, default=3)
    parser.add_argument("--warmup", type=float, default=8)
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--max-idle-spawns", type=int, default=0)
    args = parser.parse_args()
    plugin = Path(args.plugin).resolve()
    sys.path.insert(0, str(kit_preview(plugin)))
    import harness  # noqa: E402

    run = harness.Run(args.host, SHELL, plugin=plugin, prefix="foamy-monitor-idle-")
    try:
        home = Path(run.env["HOME"])
        (home / ".config/hypr").mkdir(parents=True)
        (home / ".config/hypr/monitors.lua").write_text(CONFIG)
        fake = fakebin.write(run.base / "bin", count=args.instances)
        log = run.base / "calls.log"
        run.env.update({"PATH": f"{fake}:/usr/bin", "FOAMY_CALLS": str(log), "FOAMY_INSTANCES": str(args.instances)})
        with (run.base / "qs.log").open("w") as output:
            process = subprocess.Popen(["qs", "-p", str(run.root), "--no-color"], env=run.env, stdout=output,
                                       stderr=output, start_new_session=True)
            try:
                time.sleep(args.warmup)
                if process.poll() is not None:
                    raise SystemExit("qs exited early:\n" + (run.base / "qs.log").read_text()[-3000:])
                start_cpu, start_calls = cpu_seconds(process.pid), len(calls(log))
                time.sleep(args.seconds)
                end_cpu, window = cpu_seconds(process.pid), calls(log)[start_calls:]
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
        used = end_cpu - start_cpu
        startup = calls(log)[:start_calls]
        print(f"plugin {plugin} host {args.host}, {args.instances} instances, idle window {args.seconds:.0f} s")
        print(f"startup calls: {len(startup)}  ({', '.join(sorted(set(c.split(chr(9))[0] + ' ' + (c.split(chr(9))[2] if len(c.split(chr(9))) > 2 and c.startswith('python3') else '') for c in startup)))})")
        print(f"idle calls: {len(window)}  idle CPU: {used:.2f} s = {100 * used / args.seconds:.2f} % of one core")
        kinds = {}
        for line in window:
            parts = line.split("\t")
            key = parts[0] + (" " + Path(parts[1].split()[0]).name + " " + " ".join(parts[1].split()[1:2]) if parts[0] == "python3" else "")
            kinds[key] = kinds.get(key, 0) + 1
        for key, count in sorted(kinds.items()):
            print(f"  {count:5d}  {key}")
        brightness = [c for c in startup if c.startswith("omarchy-brightness-display")]
        print(f"startup brightness probes: {len(brightness)}")
        spawned = len(window)
        failures = [l for l in (run.base / "qs.log").read_text().splitlines() if "TypeError" in l or "ReferenceError" in l]
        for line in failures[:10]:
            print("  qml: " + line)
        if spawned > args.max_idle_spawns:
            print(f"FAIL: {spawned} processes started while idle (allowed {args.max_idle_spawns})")
            return 1
        print("OK")
        return 0
    finally:
        if not os.environ.get("FOAMY_KEEP"):
            run.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
