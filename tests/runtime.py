#!/usr/bin/env python3
"""Load Foamy Monitor offscreen on Omarchy 4.5
with the foamy-kit harness: isolated HOME/XDG/runtime dirs, no Wayland or
Hyprland, and fake hyprctl/brightness/gsettings/text-size script/FluxCast/
ffmpeg and a logging bash on a PATH without Omarchy's scripts
(tests/fakebin.py). Checks
tests/qml/Runtime.qml; the leader's IPC (its function names, `status`, and
`brightness` refusing junk); from the fakes' calls: that brightness jobs never
overlapped, the cast's FluxCast command, the text size and cursor size
commands, that the stop of a stubborn scan met a FluxCast that ignored it,
and that the teardown stopped the running cast.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness.
The host is Omarchy 4.5: FOAMY_HOST_45, else $OMARCHY_TEST_ROOT/shell, else
the installed /usr/share/omarchy/shell."""

import json
import os
from pathlib import Path
import subprocess
import sys

PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN / "tests"))
import fakebin  # noqa: E402

KIT = Path(os.environ.get("FOAMY_KIT", Path.home() / "GitHub/Personal/foamy-kit"))
if not (KIT / "preview/harness.py").exists():
    raise SystemExit(f"foamy-kit harness not found at {KIT} (set FOAMY_KIT)")
# Omarchy 4.5 only by default; set before the harness reads its hosts.
if not os.environ.get("FOAMY_HOST_45"):
    _root = os.environ.get("OMARCHY_TEST_ROOT")
    os.environ["FOAMY_HOST_45"] = str(Path(_root) / "shell") if _root else "/usr/share/omarchy/shell"
sys.path.insert(0, str(KIT / "preview"))
import harness  # noqa: E402

CONFIG = """local omarchy_monitor_scale = "auto"
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
local omarchy_gdk_scale = 2
hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
"""


# The IPC functions that keybindings and scripts call (README "IPC").
IPC_FUNCTIONS = {
    "open",
    "close",
    "toggle",
    "show",
    "hide",
    "scanWireless",
    "stopWireless",
    "status",
    "state",
    "brightness",
}


def instance(run):
    """The qs instance id once the scene logged FOAMY READY and its IPC socket exists."""
    if not run.wait_for_log("FOAMY READY", timeout=60):
        return None
    by_id = Path(run.env["XDG_RUNTIME_DIR"]) / "quickshell/by-id"
    sockets = harness.wait_for(lambda: sorted(by_id.glob("*/ipc.sock")), 10)
    return sockets[0].parent.name if sockets else None


def ipc(run, ident, *args):
    """stdout of `qs ipc -i <ident> <args>`, or None when it failed."""
    result = subprocess.run(["qs", "ipc", "-i", ident, *args], env=run.env, capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else None


def ipc_targets(shown):
    """{target: [function names]} from `qs ipc show`."""
    targets, current = {}, None
    for line in (shown or "").splitlines():
        words = line.split()
        if words[:1] == ["target"] and len(words) > 1:
            current = words[1]
            targets.setdefault(current, [])
        elif words[:1] == ["function"] and current is not None and len(words) > 1:
            targets[current].append(words[1].split("(", 1)[0])
    return targets


def ipc_failures(run):
    """What is wrong with the leader's IPC, asked while the scene runs. Every
    call is read-only or refused before it changes anything."""
    ident = instance(run)
    if ident is None:
        return ["no qs IPC instance"]
    failures = []
    shown = ipc(run, ident, "show")
    targets = ipc_targets(shown)
    # Only the leader registers the target, so there is exactly one.
    if sorted(targets.get("foamy.monitor", [])) != sorted(IPC_FUNCTIONS):
        failures.append(f"IPC foamy.monitor functions: {shown!r}")
    if shown is not None and shown.count("target foamy.monitor") != 1:
        failures.append(f"IPC foamy.monitor is not registered exactly once: {shown!r}")
    status = ipc(run, ident, "call", "foamy.monitor", "status")
    try:
        reply = json.loads(status or "")
    except ValueError:
        reply = None
    if not isinstance(reply, dict):
        failures.append(f"IPC status is no JSON object: {status!r}")
    else:
        for key, want in (("leader", True), ("members", 3), ("focusedMonitor", "eDP-1")):
            if reply.get(key) != want:
                failures.append(f"IPC status {key}: {reply.get(key)!r}, expected {want!r}")
        if len(reply.get("displays") or []) != 3:
            failures.append(f"IPC status displays: {reply.get('displays')!r}, expected 3")
    junk = ipc(run, ident, "call", "foamy.monitor", "brightness", "abc")
    if junk != "error: expected a percentage such as 40, +5 or -5":
        failures.append(f"IPC brightness abc: {junk!r}")
    return failures


def calls_failures(lines):
    """What the fakes' calls say is wrong (lines of $FOAMY_CALLS)."""
    failures = []
    # The cast picked in the scene: the first receiver after the TTL rescan
    # (Den), on panel(1)'s selected display, which is the focused eDP-1; the
    # rest is MonitorService.connectWirelessPeer's fixed stream settings.
    cast = "\t".join(
        ["fluxcast", "--protocol", "wfd", "--wfd-peer", "0A:0B:0C:0D:0E:0F", "--monitor", "eDP-1"]
        + ["--output-res", "1920x1080", "--fps", "30", "--bitrate", "4M", "--wfd-timeout", "8"]
    )
    at = next((i for i, line in enumerate(lines) if line.startswith("fluxcast\t") and "--wfd-peer" in line), None)
    if at is None or lines[at] != cast:
        failures.append(f"the cast's FluxCast command: {lines[at] if at is not None else None!r}")
    else:
        # The refresh it interrupted was stopped (SIGINT) before the cast began.
        before = [line for line in lines[:at] if line.startswith(("fluxcast\t", "fluxcast-signal\t"))]
        if not before or before[-1] != "fluxcast-signal\t2":
            failures.append(f"the cast began before the scan stopped: {before[-1:]}")
    # The Advanced text size reaches its script with the chosen value.
    if "omarchy-display-text-size\t12" not in lines:
        failures.append("no call of omarchy-display-text-size with 12")
    # The cursor size reaches gsettings, and hyprctl gets the theme without
    # the quotes that gsettings prints around it.
    for call in ("gsettings\tset\torg.gnome.desktop.interface\tcursor-size\t48", "hyprctl\tsetcursor\tAdwaita\t48"):
        if call not in lines:
            failures.append(f"no call {call!r} for the cursor size")
    if "fluxcast-ignored\t2" not in lines:
        failures.append("the stubborn scan's first stop did not meet a FluxCast that ignored it")
    # Only the lines between the two markers count: when qs exits, the cast's
    # bridge dies and FluxCast gets SIGINT, whatever the teardown did.
    if "teardown-start" not in lines:
        failures.append("the scene never reached the teardown")
    elif "teardown-done" not in lines:
        failures.append("the scene never finished the teardown")
    elif not any(
        line.startswith("fluxcast-signal\t")
        for line in lines[lines.index("teardown-start") + 1 : lines.index("teardown-done")]
    ):
        failures.append("the teardown did not stop the running cast")
    return failures


def overlaps(path):
    events = [line.split() for line in path.read_text().splitlines()] if path.exists() else []
    depth, worst = 0, 0
    for kind, _ in sorted(events, key=lambda e: float(e[1])):
        depth += 1 if kind == "start" else -1
        worst = max(worst, depth)
    return worst, sum(1 for e in events if e[0] == "start")


def run(host, lang, theme="dark"):
    shell = (PLUGIN / "tests/qml/Runtime.qml").read_text()
    r = harness.Run(
        host, shell, plugin=PLUGIN, theme=theme, language=lang, prefix=f"foamy-monitor-runtime-{host}-{lang}-"
    )
    home = Path(r.env["HOME"])
    (home / ".config/hypr").mkdir(parents=True)
    (home / ".config/hypr/monitors.lua").write_text(CONFIG)
    fake = fakebin.write(r.base / "bin", count=3)
    calls = r.base / "calls.log"
    # The fakes first, then the harness's PATH: any other omarchy-* command
    # is a stub that exits 127 and is logged (Run.host_commands()).
    r.env.update(
        FOAMY_LANG=lang,
        FOAMY_HOLD_MS="500",
        PATH=f"{fake}:{r.env['PATH']}",
        FOAMY_CALLS=str(calls),
        FOAMY_FAKEBIN=str(fake),
        # The scene checks that the dim red is in effect.
        FOAMY_THEME=Path(theme).stem,
    )
    r.start()
    try:
        ipc_problems = ipc_failures(r)
        r.wait(timeout=240)
    finally:
        r.stop()
    log = r.log
    result = next(
        (line.split("FOAMY RESULT ", 1)[1] for line in log.splitlines() if "FOAMY RESULT" in line), "no result"
    )
    failures = [
        line for line in log.splitlines() if "FOAMY FAIL" in line or any(m in line for m in harness.FAILURE_MARKERS)
    ]
    failures += ipc_problems
    depth, jobs = overlaps(Path(str(calls) + ".ddc"))
    if depth != 1:
        failures.append(f"brightness jobs overlapped (max {depth} at once, {jobs} jobs)")
    failures += calls_failures(calls.read_text().splitlines() if calls.exists() else [])
    failures += [f"ran a host command: {line}" for line in r.host_commands()]
    # The hung brightness command (fakebin ddchang) ran, and nothing of it is left.
    hang_pid = Path(str(calls) + ".ddchang.pid")
    if not hang_pid.exists():
        failures.append("the hung brightness command never ran")
    elif Path("/proc", hang_pid.read_text().strip()).exists():
        failures.append("the hung brightness command outlived its deadline")
    ok = "FOAMY DONE" in log and not failures
    print(
        f"{'PASS' if ok else 'FAIL'} runtime {host} {lang} {Path(theme).stem}: {result}; "
        f"{jobs} brightness jobs, max {depth} at once"
    )
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
        print(f"    log kept at {r.base}")
    elif not os.environ.get("FOAMY_KEEP"):
        r.cleanup()
    return ok


if __name__ == "__main__":
    # A dark theme with a dim red (2.70:1 on its background), where the error
    # lines must lighten until they read, and the light theme, where the
    # footer's yellow must darken until it reads on the trial's fill.
    dim_red = KIT / "tests/fixtures/themes/dim-red.toml"
    if not dim_red.is_file():
        raise SystemExit(f"the dim-red theme is missing at {dim_red} (update FOAMY_KIT)")
    cases = [("4.5", "en", "dark"), ("4.5", "ar", "dark"), ("4.5", "en", dim_red), ("4.5", "en", "light")]
    if len(sys.argv) > 1:
        cases = [c for c in cases if c[0] in sys.argv[1:] or f"{c[0]}/{c[1]}" in sys.argv[1:]]
    results = [run(host, lang, theme) for host, lang, theme in cases]
    raise SystemExit(0 if all(results) else 1)
