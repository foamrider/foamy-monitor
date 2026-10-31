#!/usr/bin/env python3
"""Shared fakes for the offscreen runtime tests: hyprctl, brightness, gsettings.

Each fake is a small script written into a temporary bin directory. They log
every call to $FOAMY_CALLS and never touch the
live session, displays or DDC buses.
"""
import json
import os
import stat
from pathlib import Path


def monitors(count):
    rows = []
    for index in range(count):
        name = "eDP-1" if index == 0 else f"DP-{index}"
        rows.append({
            "id": index, "name": name, "description": f"Foamy Test {name}",
            "make": "Foamy", "model": f"Test {index}", "serial": f"S{index}",
            "width": 1920, "height": 1080, "refreshRate": 60.0, "x": index * 1920, "y": 0,
            "scale": 1.0, "transform": 0, "disabled": False, "focused": index == 0,
            "mirrorOf": "none", "availableModes": ["1920x1080@60.00Hz", "1280x720@60.00Hz"],
        })
    return rows


LOGGER = '''import os, sys, time
with open(os.environ["FOAMY_CALLS"], "a") as log:
    log.write("\\t".join([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
'''


def write(directory, count=3, brightness=50):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "monitors.json").write_text(json.dumps(monitors(count)))
    scripts = {
        "hyprctl": LOGGER + '''
args = sys.argv[1:]
if args[:1] == ["monitors"]:
    # Read the outputs first, then take the configured time to answer: a change
    # made while this runs is not in its answer (like a real in-flight query).
    snapshot = open(os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "monitors.json")).read()
    delay = os.environ["FOAMY_CALLS"] + ".hyprdelay"
    if os.path.exists(delay):
        time.sleep(float(open(delay).read() or 0))
    print(snapshot)
elif args[:1] == ["configerrors"]:
    pass
elif args[:1] in (["eval"], ["reload"], ["setcursor"]):
    print("ok")
''',
        "omarchy-brightness-display": LOGGER + '''
with open(os.environ["FOAMY_CALLS"] + ".ddc", "a") as ddc:
    ddc.write("start %f\\n" % time.monotonic())
time.sleep(0.05)
with open(os.environ["FOAMY_CALLS"] + ".ddc", "a") as ddc:
    ddc.write("end %f\\n" % time.monotonic())
if any(a.endswith("%") for a in sys.argv[1:]):
    # Like hardware, a written level reads back.
    with open(os.environ["FOAMY_CALLS"] + ".brightness", "w") as level:
        level.write(sys.argv[-1].rstrip("%"))
    sys.exit(0)
level = os.environ["FOAMY_CALLS"] + ".brightness"
print(open(level).read().strip() if os.path.exists(level) else "%d" % BRIGHTNESS)
''',
        "gsettings": LOGGER + 'print("24" if "cursor-size" in sys.argv else "\'Adwaita\'")\n',
        "omarchy-display-text-size": LOGGER,
        # FluxCast double: a scan that runs until stopped, logging the signal.
        # With $FOAMY_CALLS.peers present a scan instead finishes after
        # $FOAMY_CALLS.scandelay seconds (default 0.8) and prints those peers
        # (FluxCast's "[n] MAC name via source" lines).
        "fluxcast": LOGGER + '''
import signal
def stop(number, _frame):
    with open(os.environ["FOAMY_CALLS"], "a") as log:
        log.write("fluxcast-signal\\t%d\\n" % number)
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
peers = os.environ["FOAMY_CALLS"] + ".peers"
if "--wfd-scan" in sys.argv and os.path.exists(peers):
    delay = os.environ["FOAMY_CALLS"] + ".scandelay"
    time.sleep(float(open(delay).read()) if os.path.exists(delay) else 0.8)
    print(open(peers).read(), flush=True)
    sys.exit(0)
time.sleep(30)
''',
        "python3": '''#!/bin/sh
printf 'python3\\t%s\\n' "$*" >> "$FOAMY_CALLS"
exec /usr/bin/python3 "$@"
''',
    }
    for name, body in scripts.items():
        path = directory / name
        text = body if body.startswith("#!") else "#!/usr/bin/python3\n" + body.replace("BRIGHTNESS", str(brightness))
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return directory
