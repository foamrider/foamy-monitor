#!/usr/bin/env python3
"""Shared display drafts and a detached, bounded Hyprland display trial."""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from typing import Any

from display_config import gtk_scale_setting, lua_string, monitor_rule, update_config, update_gtk_scale


EDITABLE = ("width", "height", "refreshRate", "scale", "transform", "x", "y", "disabled", "mirrorOf")
ACTIVE = ("applying", "testing", "saving", "reverting")
MODE = re.compile(r"^(\d+)x(\d+)@([\d.]+)Hz$")
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "hypr/monitors.lua"


def run(*args: str, timeout: float = 5) -> str:
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout).strip() or f"{args[0]} failed ({result.returncode})")
    return result.stdout.strip()


def live_monitors() -> list[dict[str, Any]]:
    rows = json.loads(run("hyprctl", "monitors", "all", "-j"))
    if not isinstance(rows, list) or not rows:
        raise ValueError("No connected displays")
    descriptions = [str(m.get("description", "")) for m in rows]
    output_names = {str(m["id"]): m["name"] for m in rows}
    result = []
    for row in rows:
        description = str(row.get("description", ""))
        unique = description and descriptions.count(description) == 1
        selector = "desc:" + description if unique else row["name"]
        modes = []
        for text in row.get("availableModes", []):
            match = MODE.fullmatch(text)
            if match:
                mode = (int(match[1]), int(match[2]), float(match[3]))
                if mode not in modes:
                    modes.append(mode)
        width, height = int(row["width"]), int(row["height"])
        rate = float(row["refreshRate"])
        if width == 0 or height == 0:
            width, height, rate = modes[0] if modes else (0, 0, 60.0)
        same_size = [m for m in modes if m[:2] == (width, height)]
        if same_size:
            rate = min(same_size, key=lambda m: abs(m[2] - rate))[2]
        metadata = {key: row[key] for key in ("name", "make", "model", "serial", "scale", "transform", "disabled", "focused", "availableModes")}
        # Hyprland reports mirrorOf as a monitor ID, while hl.monitor takes a selector.
        mirror = row.get("mirrorOf")
        mirror_name = "" if mirror in (None, "none", "") else output_names.get(str(mirror), str(mirror))
        result.append(dict(metadata, id=selector, selector=selector, description=description,
                           width=width, height=height, refreshRate=rate, connected=True,
                           mirrorOf=mirror_name,
                           x=max(0, int(row["x"])) if row["disabled"] else int(row["x"]),
                           y=max(0, int(row["y"])) if row["disabled"] else int(row["y"])))
    return result


def same(a: Any, b: Any) -> bool:
    if isinstance(a, (int, float)) and not isinstance(a, bool):
        return isinstance(b, (int, float)) and math.isclose(a, b, abs_tol=0.00001)
    return a == b


def footprint(m: dict[str, Any]) -> tuple[int, int]:
    w, h = round(m["width"] / m["scale"]), round(m["height"] / m["scale"])
    return (h, w) if m["transform"] % 2 else (w, h)


def validate(monitors: list[dict[str, Any]], live: list[dict[str, Any]]) -> None:
    if {m["id"] for m in monitors} != {m["id"] for m in live}:
        raise ValueError("Displays changed. Discard the draft and try again")
    by_name = {m["name"]: m for m in monitors}
    if not any(not m["disabled"] and not m["mirrorOf"] for m in monitors):
        raise ValueError("Keep at least one display enabled")
    for m in monitors:
        if m["disabled"]:
            continue
        advertised = [MODE.fullmatch(v) for v in m["availableModes"]]
        if not any(v and int(v[1]) == m["width"] and int(v[2]) == m["height"] and
                   abs(float(v[3]) - m["refreshRate"]) < 0.02 for v in advertised):
            original = next(v for v in live if v["id"] == m["id"])
            if any(not same(m[k], original[k]) for k in ("width", "height", "refreshRate")):
                raise ValueError(f'Unsupported resolution or refresh rate for {m["name"]}')
        if not 0.25 <= m["scale"] <= 8 or any(abs(v / m["scale"] - round(v / m["scale"])) > 0.001 for v in (m["width"], m["height"])):
            raise ValueError(f'Unsupported scale for {m["name"]}')
        if m["mirrorOf"]:
            target = by_name.get(m["mirrorOf"])
            if not target or target["disabled"] or target["mirrorOf"] or target is m:
                raise ValueError("Choose an enabled, non-mirrored source display")
    extended = [m for m in monitors if not m["disabled"] and not m["mirrorOf"]]
    for i, a in enumerate(extended):
        aw, ah = footprint(a)
        for b in extended[i + 1:]:
            bw, bh = footprint(b)
            if a["x"] < b["x"] + bw and a["x"] + aw > b["x"] and a["y"] < b["y"] + bh and a["y"] + ah > b["y"]:
                raise ValueError("Displays overlap. Adjust their arrangement")


def atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    fd, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Store:
    def __init__(self, directory: Path | None = None):
        session = hashlib.sha256(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "default").encode()).hexdigest()[:16]
        self.directory = directory or Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/foamy-{os.getuid()}")) / ("foamy-monitor-" + session)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / "state.json"

    @contextmanager
    def lock(self, name: str = "state.lock", blocking: bool = True):
        with (self.directory / name).open("a") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
            yield

    def read(self) -> dict[str, Any]:
        if not self.path.exists():
            return {"phase": "idle", "base": [], "draft": [], "error": "", "revision": 0}
        return json.loads(self.path.read_text())

    def write(self, state: dict[str, Any]) -> None:
        state["revision"] = state.get("revision", 0) + 1
        atomic_write(self.path, json.dumps(state))


def reconcile(state: dict[str, Any], live: list[dict[str, Any]]) -> None:
    if state["phase"] in ACTIVE:
        return
    base = {m["id"]: m for m in state["base"]}
    draft = {m["id"]: m for m in state["draft"]}
    new_base, new_draft = [], []
    for monitor in live:
        key = monitor["id"]
        old_base, old_draft = base.get(key, monitor), draft.get(key, monitor)
        b, d = copy.deepcopy(monitor), copy.deepcopy(monitor)
        for field in EDITABLE:
            if not same(old_base[field], old_draft[field]):
                b[field], d[field] = old_base[field], old_draft[field]
        new_base.append(b)
        new_draft.append(d)
    connected = {m["id"] for m in live}
    for key in draft.keys() - connected:
        if any(not same(base[key][k], draft[key][k]) for k in EDITABLE):
            new_base.append(dict(base[key], connected=False))
            new_draft.append(dict(draft[key], connected=False))
    state["base"], state["draft"] = new_base, new_draft


def apply(monitors: list[dict[str, Any]]) -> None:
    # Enable source outputs before mirrors, and disable old outputs last.
    ordered = sorted(monitors, key=lambda m: (m["disabled"], bool(m["mirrorOf"])))
    result = run("hyprctl", "eval", "; ".join(monitor_rule(m) for m in ordered))
    if result.lower().startswith("error"):
        raise RuntimeError(result)


def verify(expected: list[dict[str, Any]], actual: list[dict[str, Any]]) -> bool:
    by_id = {m["id"]: m for m in actual}
    for m in expected:
        got = by_id.get(m["id"])
        if not got or got["disabled"] != m["disabled"]:
            return False
        if m["disabled"]:
            continue
        fields = ("width", "height", "refreshRate", "scale", "transform", "mirrorOf")
        if not m["mirrorOf"]:
            fields += ("x", "y")
        if any(not same(m[k], got[k]) for k in fields):
            return False
    return True


def wait_verified(expected: list[dict[str, Any]], seconds: float = 4) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if verify(expected, live_monitors()):
            return
        time.sleep(0.15)
    raise RuntimeError("The display did not accept these settings")


def rollback(snapshot: list[dict[str, Any]]) -> None:
    connected = live_monitors()
    names = {m["id"]: m["name"] for m in connected}
    restore = [dict(m, name=names[m["id"]]) for m in snapshot if m["id"] in names]
    # A disconnected source must not leave the remaining monitor disabled/mirrored.
    available = {m["name"] for m in restore}
    for m in restore:
        if m["mirrorOf"] not in available:
            m["mirrorOf"] = ""
    if not any(not m["disabled"] for m in restore):
        fallback = next((m for m in connected if re.match(r"^(eDP|LVDS|DSI)-", m["name"])), connected[0])
        restore = [dict(fallback, disabled=False, mirrorOf="", x=0, y=0, scale=1)]
    apply(restore)
    wait_verified(restore)


def worker(store: Store, token: str) -> None:
    with store.lock("trial.lock"):
        state = store.read()
        if state.get("token") != token or state["phase"] != "applying":
            return
        snapshot, proposed = state["snapshot"], state["draft"]
        config_before, config_after = state["configBefore"], state["configAfter"]
        gtk = state.get("gtkScale", {})
        gtk_changed = gtk.get("base") != gtk.get("value")
        old_environment = state.get("gtkEnvironmentBefore")
        monitor_changes = state.get("monitorChanges", True)
        applied_gtk = False
        wrote_config = False
        reason = ""
        cancelled = False

        def cancel(_signal, _frame):
            nonlocal cancelled
            cancelled = True

        signal.signal(signal.SIGTERM, cancel)
        signal.signal(signal.SIGINT, cancel)
        try:
            if monitor_changes:
                apply(proposed)
                wait_verified(proposed)
            if gtk_changed:
                # Runtime-only until Keep; mark first so partial failures also restore it.
                applied_gtk = True
                apply_gtk_scale(gtk["value"])
            deadline = time.monotonic() + 15
            with store.lock():
                state = store.read()
                state.update(phase="testing", deadline=time.time() + 15)
                store.write(state)
            while time.monotonic() < deadline and not cancelled:
                time.sleep(0.15)
                state = store.read()
                if state.get("decision") == "revert":
                    break
                current = live_monitors()
                if {m["id"] for m in current} != {m["id"] for m in snapshot}:
                    raise RuntimeError("A display was disconnected during the test")
                if state.get("decision") != "keep":
                    continue
                if time.monotonic() >= deadline:
                    break
                wait_verified(proposed, 1)
                if CONFIG.read_text() != config_before:
                    raise RuntimeError("monitors.lua changed during the test; try again")
                with store.lock():
                    state = store.read()
                    state["phase"] = "saving"
                    store.write(state)
                atomic_write(store.directory / "monitors.lua.backup", config_before)
                atomic_write(CONFIG, config_after, CONFIG.stat().st_mode & 0o777)
                wrote_config = True
                reload_config(monitor_changes)
                errors = run("hyprctl", "configerrors")
                if errors:
                    raise RuntimeError(errors)
                wait_verified(proposed)
                with store.lock():
                    state = store.read()
                    state.update(phase="idle", base=proposed, draft=proposed, error="", deadline=0)
                    if gtk_changed:
                        state["gtkScale"] = {"base": gtk["value"], "value": gtk["value"]}
                    store.write(state)
                return
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            reason = str(error)
        with store.lock():
            state = store.read()
            state["phase"] = "reverting"
            store.write(state)
        try:
            if wrote_config:
                if CONFIG.read_text() == config_after:
                    atomic_write(CONFIG, config_before, CONFIG.stat().st_mode & 0o777)
                    reload_config(monitor_changes)
                else:
                    reason += " Configuration changed externally; its backup is in " + str(store.directory / "monitors.lua.backup")
            if monitor_changes:
                rollback(snapshot)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            reason += " Could not restore displays: " + str(error)
        if applied_gtk:
            try:
                restore_gtk_scale(gtk["base"], old_environment)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
                reason += " Could not restore GTK scale: " + str(error)
        with store.lock():
            state = store.read()
            state.update(phase="idle", base=snapshot, draft=snapshot, error=reason.strip(), deadline=0)
            if gtk_changed:
                state["gtkScale"] = {"base": gtk["base"], "value": gtk["base"]}
            store.write(state)


def patch(state: dict[str, Any], request: dict[str, Any]) -> None:
    if not isinstance(request, dict) or not isinstance(request.get("changes"), dict):
        raise ValueError("Invalid display change")
    monitor = next((m for m in state["draft"] if m["id"] == request.get("id")), None)
    if not monitor or not monitor["connected"]:
        raise ValueError("Display is disconnected")
    for key, value in request["changes"].items():
        if key not in EDITABLE:
            raise ValueError("Unknown display setting")
        if key == "disabled":
            valid = isinstance(value, bool)
        elif key == "mirrorOf":
            valid = isinstance(value, str) and len(value) < 256
        else:
            valid = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
            if valid and key not in ("scale", "refreshRate"):
                valid = int(value) == value and abs(value) < 100000
            if valid and key == "transform":
                valid = 0 <= value <= 7
            if valid and key in ("scale", "refreshRate", "width", "height"):
                valid = value > 0
        if not valid:
            raise ValueError("Invalid display setting: " + key)
        monitor[key] = value
    if not any(not m["disabled"] and m["connected"] and not m["mirrorOf"] for m in state["draft"]):
        raise ValueError("Keep at least one display enabled")
    state["error"] = ""


def reload_config(monitor_changes: bool) -> None:
    # GTK-only saves must not reapply unrelated monitor geometry.
    run("hyprctl", "reload", *([] if monitor_changes else ["config-only"]))


def apply_gtk_scale(value: int) -> None:
    result = run("hyprctl", "eval", 'hl.env("GDK_SCALE", ' + lua_string(str(value)) + ')')
    if result.lower().startswith("error"):
        raise RuntimeError(result)
    run("dbus-update-activation-environment", "--systemd", f"GDK_SCALE={value}")


def restore_gtk_scale(value: int, environment: str | None) -> None:
    result = run("hyprctl", "eval", 'hl.env("GDK_SCALE", ' + lua_string(str(value)) + ')')
    if result.lower().startswith("error"):
        raise RuntimeError(result)
    run("dbus-update-activation-environment", "--systemd", "GDK_SCALE=" + (environment or ""))
    if environment is None:
        run("systemctl", "--user", "unset-environment", "GDK_SCALE")


def command(store: Store, action: str, request: dict[str, Any]) -> dict[str, Any]:
    with store.lock():
        state = store.read()
        previous = copy.deepcopy(state)
        live = live_monitors()
        reconcile(state, live)
        gtk_error = ""
        try:
            current_gtk = gtk_scale_setting(CONFIG.read_text())[0]
        except (OSError, ValueError) as error:
            current_gtk, gtk_error = None, str(error)
        gtk = state.get("gtkScale", {"base": current_gtk, "value": current_gtk})
        # Polling follows external edits only while this global setting is clean.
        if state["phase"] not in ACTIVE and gtk["base"] == gtk["value"]:
            gtk = {"base": current_gtk, "value": current_gtk}
        state["gtkScale"] = gtk
        if action in ("patch", "discard", "apply", "gtk-scale") and state["phase"] in ACTIVE:
            raise ValueError("A display test is already running")
        if action == "patch":
            patch(state, request)
        elif action == "gtk-scale":
            if gtk_error:
                raise ValueError(gtk_error)
            value = request.get("value")
            update_gtk_scale(CONFIG.read_text(), value)
            gtk["value"] = value
            state["error"] = ""
        elif action == "discard":
            state.update(base=live, draft=live, error="")
            state["gtkScale"] = {"base": current_gtk, "value": current_gtk}
        elif action == "apply":
            validate(state["draft"], live)
            actual = {m["id"]: m for m in live}
            for base, draft in zip(state["base"], state["draft"]):
                if any(not same(base[k], draft[k]) and not same(base[k], actual[base["id"]][k]) for k in EDITABLE):
                    raise ValueError("Display settings changed elsewhere. Discard the draft and try again")
            edited = [draft for base, draft in zip(state["base"], state["draft"])
                      if any(not same(base[k], draft[k]) for k in EDITABLE)]
            gtk_changed = gtk["base"] != gtk["value"]
            if gtk_changed and (gtk_error or current_gtk != gtk["base"]):
                raise ValueError(gtk_error or "GTK scale changed elsewhere. Discard the draft and try again")
            if not edited and not gtk_changed:
                raise ValueError("No unsaved changes")
            if CONFIG.is_symlink():
                raise ValueError("monitors.lua must be a machine-local file outside Stow")
            config = CONFIG.read_text()
            if run("hyprctl", "configerrors"):
                raise ValueError("Fix Hyprland configuration errors before saving")
            token = uuid.uuid4().hex
            config_after = update_config(config, edited, state["draft"]) if edited else config
            if gtk_changed:
                config_after = update_gtk_scale(config_after, gtk["value"])
                state["gtkEnvironmentBefore"] = next((line.split("=", 1)[1]
                    for line in run("systemctl", "--user", "show-environment").splitlines()
                    if line.startswith("GDK_SCALE=")), None)
            state.update(phase="applying", token=token, snapshot=live, decision="", error="",
                         configBefore=config, configAfter=config_after, monitorChanges=bool(edited))
            store.write(state)
            # No inherited pipes or process group: the watchdog survives Quickshell.
            try:
                child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", "--token", token],
                                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                         start_new_session=True, close_fds=True)
            except OSError:
                state["phase"] = "idle"
                store.write(state)
                raise
            state["workerPid"] = child.pid
        elif action in ("keep", "revert"):
            if state["phase"] != "testing" or request.get("token") != state.get("token"):
                raise ValueError("This display test has ended")
            state["decision"] = action
        if state != previous:
            store.write(state)
        return {"ok": True, "state": {k: v for k, v in state.items() if k not in ("configBefore", "configAfter", "snapshot", "gtkEnvironmentBefore")},
                "live": live, "gtkScale": dict(state["gtkScale"], error=gtk_error)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "patch", "discard", "apply", "keep", "revert", "worker", "gtk-scale"])
    parser.add_argument("--token", default="")
    args = parser.parse_args()
    store = Store()
    try:
        if args.action == "worker":
            worker(store, args.token)
            return 0
        request = json.loads(sys.stdin.readline()) if args.action in ("patch", "keep", "revert", "gtk-scale") else {}
        print(json.dumps(command(store, args.action, request)), flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
