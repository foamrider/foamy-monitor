#!/usr/bin/env python3
"""The popup's buttons under a real pointer and the keys
(tests/qml/Buttons.qml), offscreen on Omarchy 4.5 with the foamy-kit
harness and the fake hyprctl, brightness and gsettings of tests/fakebin.py,
in the dark and light themes. See the scene for what it checks.

FOAMY_KIT (default ~/GitHub/Personal/foamy-kit) provides the harness; the
host is the one tests/runtime.py uses."""

import os
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fakebin  # noqa: E402
import runtime  # noqa: E402  (sets the 4.5 host and imports the harness)

harness = runtime.harness


def run(theme):
    r = harness.Run(
        "4.5",
        (HERE / "qml/Buttons.qml").read_text(),
        plugin=runtime.PLUGIN,
        theme=theme,
        language="en",
        prefix=f"foamy-monitor-buttons-{theme}-",
    )
    home = Path(r.env["HOME"])
    (home / ".config/hypr").mkdir(parents=True)
    (home / ".config/hypr/monitors.lua").write_text(runtime.CONFIG)
    fake = fakebin.write(r.base / "bin", count=3)
    r.env.update(
        FOAMY_LANG="en",
        PATH=f"{fake}:{r.env['PATH']}",
        FOAMY_CALLS=str(r.base / "calls.log"),
        FOAMY_FAKEBIN=str(fake),
    )
    r.start()
    try:
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
    failures += [f"ran a host command: {line}" for line in r.host_commands()]
    ok = "FOAMY DONE" in log and not failures
    print(f"{'PASS' if ok else 'FAIL'} buttons 4.5 en {theme}: {result}")
    if not ok:
        print("\n".join("    " + line for line in (failures or log.splitlines()[-40:])))
        print(f"    log kept at {r.base}")
    elif not os.environ.get("FOAMY_KEEP"):
        r.cleanup()
    return ok


if __name__ == "__main__":
    results = [run(theme) for theme in ("dark", "light")]
    raise SystemExit(0 if all(results) else 1)
