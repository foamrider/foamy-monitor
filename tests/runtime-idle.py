#!/usr/bin/env python3
"""Measure what foamy-monitor runs while its popups are closed.

Loads Panel.qml N times (one per simulated monitor, as 4.5 does) in an
isolated offscreen Quickshell with the foamy-kit harness (temp HOME/XDG,
no Wayland/Hyprland variables) and fake hyprctl/brightness/gsettings on a
PATH that holds nothing else from Omarchy. After a warm-up it counts the
processes started and the CPU used by the shell and its children while every
popup stays closed.

  tests/runtime-idle.py [--plugin DIR] [--instances 3] [--seconds 30]
                        [--max-idle-spawns N]

The host is Omarchy 4.5: FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else
the installed /usr/share/omarchy/shell.

Exits 1 when more than --max-idle-spawns processes start in the idle window
(the regression check; default 0).
"""
import argparse
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fakebin  # noqa: E402


def kit_preview(plugin):
    for candidate in (os.environ.get("FOAMY_KIT"), plugin.parent / "foamy-kit", HERE.parents[1] / "foamy-kit",
                      Path.home() / "GitHub/Personal/foamy-kit"):
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


def children(pid):
    """The pids of `pid`'s child processes (every thread's)."""
    found = []
    for task in Path(f"/proc/{pid}/task").glob("*"):
        try:
            found += (task / "children").read_text().split()
        except OSError:
            continue
    return found


def calls(path):
    return path.read_text().splitlines() if path.exists() else []


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--plugin", default=str(HERE.parent))
    parser.add_argument("--instances", type=int, default=3)
    parser.add_argument("--warmup", type=float, default=60, help="longest wait for startup to settle")
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--max-idle-spawns", type=int, default=0)
    args = parser.parse_args()
    plugin = Path(args.plugin).resolve()
    # Set before the harness reads its hosts.
    if not os.environ.get("FOAMY_HOST_45"):
        root = os.environ.get("OMARCHY_TEST_ROOT")
        os.environ["FOAMY_HOST_45"] = str(Path(root) / "shell") if root else "/usr/share/omarchy/shell"
    sys.path.insert(0, str(kit_preview(plugin)))
    import harness  # noqa: E402

    run = harness.Run("4.5", SHELL, plugin=plugin, prefix="foamy-monitor-idle-")
    try:
        home = Path(run.env["HOME"])
        (home / ".config/hypr").mkdir(parents=True)
        (home / ".config/hypr/monitors.lua").write_text(CONFIG)
        fake = fakebin.write(run.base / "bin", count=args.instances)
        log = run.base / "calls.log"
        # The fakes first, then the harness's PATH: any other omarchy-* command
        # is a stub that exits 127 and is logged (Run.host_commands()).
        run.env.update({"PATH": f"{fake}:{run.env['PATH']}", "FOAMY_CALLS": str(log),
                        "FOAMY_INSTANCES": str(args.instances)})
        run.start()
        try:
            # Warm-up: the panels loaded and the startup status (and anything
            # it started) is over: no child process and no new call for 1 s.
            if not run.wait_for_log("FOAMY READY", timeout=60):
                raise SystemExit("qs did not start:\n" + (run.base / "qs.log").read_text()[-3000:])
            quiet = {"since": time.monotonic(), "calls": -1}

            def settled():
                count = len(calls(log))
                if count != quiet["calls"] or children(run.process.pid):
                    quiet.update(since=time.monotonic(), calls=count)
                return time.monotonic() - quiet["since"] >= 1 and count > 0

            if not harness.wait_for(settled, args.warmup, interval=0.1):
                raise SystemExit(f"the startup calls did not settle within {args.warmup:.0f} s")
            start_cpu, start_calls = cpu_seconds(run.process.pid), len(calls(log))
            time.sleep(args.seconds)  # the idle window itself: time is what it measures
            end_cpu, window = cpu_seconds(run.process.pid), calls(log)[start_calls:]
        finally:
            run.stop()
        used = end_cpu - start_cpu
        startup = calls(log)[:start_calls]
        print(f"plugin {plugin} host 4.5, {args.instances} instances, idle window {args.seconds:.0f} s")
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
        failures += [f"ran a host command: {line}" for line in run.host_commands()]
        for line in failures[:10]:
            print("  qml: " + line)
        if failures:
            print(f"FAIL: {len(failures)} QML errors or host commands")
            return 1
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
