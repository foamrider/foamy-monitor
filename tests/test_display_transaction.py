#!/usr/bin/env python3
"""Black-box tests of the display helper: draft, trial worker and monitors.lua.

Every case runs the helper as a process against a compositor double: fake
hyprctl, systemctl and dbus-update-activation-environment on a PATH that
holds nothing else, temp XDG_RUNTIME_DIR and XDG_CONFIG_HOME, no D-Bus
address. Nothing reaches the live Hyprland, the session environment or the
real ~/.config/hypr/monitors.lua.

FOAMY_HELPER is the helper's argv prefix as a JSON list starting with an
absolute path (default: this machine's
bin/<arch>/foamy-monitor-helper), e.g.
  FOAMY_HELPER='["/abs/bin/aarch64/foamy-monitor-helper"]' python3 -I tests/test_display_transaction.py
"""

import json
import os
import platform
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
ACTIVE = ("applying", "testing", "saving", "reverting")


def helper():
    if os.environ.get("FOAMY_HELPER"):
        prefix = json.loads(os.environ["FOAMY_HELPER"])
        if not prefix or not Path(prefix[0]).is_absolute():
            raise SystemExit("FOAMY_HELPER must be a JSON list starting with an absolute path")
        return prefix
    return [str(PLUGIN / "bin" / platform.machine() / "foamy-monitor-helper")]


OMARCHY_CONFIG = """-- Omarchy's default monitor configuration.
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = "auto"

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })
"""


def monitor(name="DP-1", disabled=False, **changes):
    """A hyprctl `monitors all -j` row."""
    row = dict(
        name=name,
        id="desc:Test " + name,
        description="Test " + name,
        make="Test",
        model=name,
        serial=name,
        width=1920,
        height=1080,
        refreshRate=60.0,
        scale=1.0,
        transform=0,
        x=0,
        y=0,
        disabled=disabled,
        mirrorOf="",
        focused=not disabled,
        availableModes=["1920x1080@60.00Hz", "1920x1080@120.00Hz"],
    )
    row.update(changes)
    return row


FAKE_HYPRCTL = r"""
import json, os, re, sys
from pathlib import Path
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write('\t'.join(['hyprctl'] + sys.argv[1:]) + '\n')
path=Path(os.environ['TEST_DISPLAYS'])
rows=json.loads(path.read_text())
args=sys.argv[1:]
errors=Path(os.environ['TEST_CALLS'] + '.errors')
if args[0]=='monitors': print(rows if isinstance(rows, str) else json.dumps(rows))
elif args[0]=='configerrors': print(errors.read_text() if errors.exists() else os.environ.get('TEST_CONFIG_ERRORS', ''))
elif args[0]=='eval' and os.environ.get('TEST_EVAL_ERROR'):
    print('error: rejected by the test compositor')
elif args[0] in ('eval','reload'):
    if args[0]=='eval': source=args[1]
    else: source=(Path(os.environ['XDG_CONFIG_HOME'])/'hypr/monitors.lua').read_text()
    env_path=Path(os.environ['TEST_GTK_ENV'])
    environment=json.loads(env_path.read_text())
    gtk=re.search(r'hl\.env\("GDK_SCALE",\s*"(\d+)"\)',source)
    if not gtk and 'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))' in source:
        gtk=re.search(r'local omarchy_gdk_scale = (\d+)',source)
    if gtk:
        environment['compositor']=gtk[1]
        env_path.write_text(json.dumps(environment))
    monitor_source='' if args==['reload','config-only'] else source
    for body in re.findall(r'hl\.monitor\(\{(.*?)\}\)',monitor_source,re.S):
        values={}
        for key, raw in re.findall(r'(\w+)\s*=\s*("(?:\\.|[^"\\])*"|true|false|[\d.eE+-]+)',body):
            values[key]=json.loads(raw)
        target=values.get('output','')
        for row in rows:
            if target not in (row['name'],'desc:'+row['description']): continue
            if 'mode' in values:
                mode=re.fullmatch(r'(\d+)x(\d+)@([\d.]+)',values['mode'])
                row.update(width=int(mode[1]),height=int(mode[2]),refreshRate=float(mode[3]))
            if 'position' in values:
                x,y=values['position'].split('x');row.update(x=int(x),y=int(y))
            for key in ('scale','transform','disabled'):
                if key in values: row[key]=values[key]
            if 'mirror' in values: row['mirrorOf']=values['mirror']
    tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(rows));tmp.replace(path)
    print('ok')
else: sys.exit(1)
"""


FAKE_ENVIRONMENT = r"""
import json, os, sys
from pathlib import Path
with open(os.environ['TEST_CALLS'], 'a') as log:
    log.write('\t'.join([Path(sys.argv[0]).name] + sys.argv[1:]) + '\n')
path=Path(os.environ['TEST_GTK_ENV'])
environment=json.loads(path.read_text())
args=sys.argv[1:]
if Path(sys.argv[0]).name=='systemctl':
    if args==['--user','show-environment']:
        if environment['systemd'] is not None: print('GDK_SCALE='+environment['systemd'])
    elif args==['--user','unset-environment','GDK_SCALE']:
        environment['systemd']=None
else:
    value=args[-1].split('=',1)[1]
    if os.environ.get('TEST_FAIL_GTK')==value:
        print('Session bus unavailable',file=sys.stderr);sys.exit(1)
    environment['systemd']=value
    environment['dbus']=value
path.write_text(json.dumps(environment))
"""


class Compositor:
    """A temp session: fakes on PATH, monitors.lua, display rows, GTK environment."""

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="display-transaction-test-")
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        shebang = f"#!{sys.executable} -I\n"
        for name, body in (
            ("hyprctl", FAKE_HYPRCTL),
            ("systemctl", FAKE_ENVIRONMENT),
            ("dbus-update-activation-environment", FAKE_ENVIRONMENT),
        ):
            executable = self.bin / name
            executable.write_text(shebang + body)
            executable.chmod(0o700)
        self.config = self.directory / "config/hypr/monitors.lua"
        self.config.parent.mkdir(parents=True)
        self.displays = self.directory / "displays.json"
        self.gtk_environment = self.directory / "gtk-environment.json"
        self.calls = self.directory / "calls.log"
        self.errors = self.directory / "calls.log.errors"
        self.runs = 0
        self.env = {}
        self.reset()

    def reset(self, config="", displays=None, gtk="1"):
        """A fresh state directory, config, displays and environment."""
        self.finish()
        self.runs += 1
        runtime = self.directory / f"runtime-{self.runs}"
        runtime.mkdir(mode=0o700)
        if self.config.is_symlink():
            self.config.unlink()
        self.config.write_text(config)
        self.displays.write_text(json.dumps(displays if displays is not None else [monitor()]))
        self.gtk_environment.write_text(json.dumps(dict(compositor=gtk, systemd=gtk, dbus=gtk)))
        self.calls.write_text("")
        if self.errors.exists():
            self.errors.unlink()
        self.env = {
            "PATH": str(self.bin),
            "HOME": str(self.directory / "home"),
            "XDG_RUNTIME_DIR": str(runtime),
            "XDG_CONFIG_HOME": str(self.directory / "config"),
            "HYPRLAND_INSTANCE_SIGNATURE": "isolated-test",
            "TEST_DISPLAYS": str(self.displays),
            "TEST_GTK_ENV": str(self.gtk_environment),
            "TEST_CALLS": str(self.calls),
            "LANG": "C.UTF-8",
        }

    def run(self, action, request=None, extra=None, args=(), stdin=None, **popen):
        env = dict(self.env, **(extra or {}))
        text = stdin if stdin is not None else json.dumps(request if request is not None else {}) + "\n"
        return subprocess.run(
            helper() + [action, *args], input=text, text=True, capture_output=True, env=env, timeout=15, **popen
        )

    def call(self, action, request=None, extra=None):
        result = self.run(action, request, extra)
        try:
            reply = json.loads(result.stdout)
        except ValueError:
            raise AssertionError(
                f"{action}: no JSON reply (exit {result.returncode}): {result.stdout!r} {result.stderr!r}"
            ) from None
        if reply["ok"] != (result.returncode == 0):
            raise AssertionError(f"{action}: exit {result.returncode} with {reply}")
        return reply

    def wait_phase(self, phase, timeout=10):
        deadline = time.monotonic() + timeout
        result = None
        while time.monotonic() < deadline:
            result = self.call("status")
            assert result["ok"], result
            if result["state"]["phase"] == phase:
                return result
            time.sleep(0.1)
        raise AssertionError(f"Did not reach {phase}: {result}")

    @staticmethod
    def state_file(result):
        return json.loads(Path(result["statePath"]).read_text())

    def finish(self):
        """Let a detached worker finish before its state goes away."""
        if not self.env:
            return
        try:
            state = self.call("status")["state"]
            if state["phase"] == "testing":
                self.call("revert", {"token": state["token"]})
            if state["phase"] in ACTIVE:
                self.wait_phase("idle", 10)
        except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError):
            pass

    def plan(self, config, displays=None, patches=(), gtk=None):
        """Stage the changes, apply, and return (apply reply, configAfter).

        The compositor rejects the trial (hyprctl eval answers with an error),
        so the worker reverts at once and nothing is written; configAfter is
        what Keep would have saved, read from the helper's state file.
        """
        self.reset(config, displays)
        state = self.call("status")["state"]
        for name, changes in patches:
            ident = next(m["id"] for m in state["draft"] if m["name"] == name)
            reply = self.call("patch", {"id": ident, "changes": changes})
            if not reply["ok"]:
                return reply, None
        if gtk is not None:
            reply = self.call("gtk-scale", {"value": gtk})
            if not reply["ok"]:
                return reply, None
        reply = self.call("apply", extra={"TEST_EVAL_ERROR": "1"})
        if not reply["ok"]:
            return reply, None
        after = self.state_file(reply)["configAfter"]
        self.wait_phase("idle")
        if self.config.read_text() != config:
            raise AssertionError("a rejected trial wrote monitors.lua")
        return reply, after

    def cleanup(self):
        self.finish()
        self.temp.cleanup()


def after(compositor, *args, **kwargs):
    reply, config = compositor.plan(*args, **kwargs)
    if config is None:
        raise AssertionError(f"apply failed: {reply}")
    return config


class DisplayModelTests(unittest.TestCase):
    def setUp(self):
        self.c = Compositor()

    def tearDown(self):
        self.c.cleanup()

    def gtk_status(self, source):
        self.c.reset(source)
        return self.c.call("status")["gtkScale"]

    def test_gtk_scale_updates_omarchy_local_without_rewriting_calls(self):
        for source in [
            OMARCHY_CONFIG,
            OMARCHY_CONFIG.replace("= 2", "= 12; -- keep this"),
            OMARCHY_CONFIG.replace('"GDK_SCALE"', "'GDK_SCALE'"),
            "-- local omarchy_gdk_scale = 9\n" + OMARCHY_CONFIG,
        ]:
            with self.subTest(source=source):
                expected = 12 if "= 12;" in source else 2
                self.assertEqual(self.gtk_status(source), {"base": expected, "value": expected, "error": ""})
                changed = after(self.c, source, gtk=1)
                self.assertEqual(
                    changed, source.replace(f"local omarchy_gdk_scale = {expected}", "local omarchy_gdk_scale = 1")
                )
                self.assertEqual(self.gtk_status(changed)["value"], 1)
                # The same value again is no change at all.
                self.assertTrue(self.c.call("gtk-scale", {"value": 1})["ok"])
                self.assertEqual(self.c.call("apply")["error"], "No unsaved changes")

    def test_gtk_scale_rejects_dynamic_or_shared_locals(self):
        for source in [
            OMARCHY_CONFIG.replace("= 2", "= 1 + 1"),
            OMARCHY_CONFIG.replace("= 2", "= 2\n + 1"),
            OMARCHY_CONFIG.replace("= 2", "= 2.5"),
            OMARCHY_CONFIG.replace("= 2", "= compute_scale()"),
            OMARCHY_CONFIG.replace("local omarchy_gdk_scale = 2\n", ""),
            OMARCHY_CONFIG.replace("local omarchy_gdk_scale", "omarchy_gdk_scale"),
            OMARCHY_CONFIG + "omarchy_gdk_scale = 3\n",
            OMARCHY_CONFIG + "local omarchy_gdk_scale = 3\n",
            OMARCHY_CONFIG + "print(omarchy_gdk_scale)\n",
            "do\n" + OMARCHY_CONFIG + "end\n",
            "local tostring = custom\n" + OMARCHY_CONFIG,
            OMARCHY_CONFIG + 'hl.env("GDK_SCALE", "1")\n',
        ]:
            with self.subTest(source=source):
                gtk = self.gtk_status(source)
                self.assertIsNone(gtk["base"])
                self.assertIn("monitors.lua", gtk["error"])
                reply = self.c.call("gtk-scale", {"value": 1})
                self.assertEqual(reply["error"], gtk["error"])

    def test_gtk_scale_messages(self):
        local = "GTK scale must use a standalone local whole number without reassignments or other uses in monitors.lua"
        for source, message in [
            (OMARCHY_CONFIG.replace("= 2", "= 1 + 1"), local),
            (
                'if docked then hl.env("GDK_SCALE", "2") end',
                "GTK scale must be a standalone hl.env call in monitors.lua",
            ),
            ('x = 1 hl.env("GDK_SCALE", "2")', "GTK scale must be a standalone hl.env call in monitors.lua"),
            ('hl.env("GDK_SCALE", tostring(scale))', local),
            (
                'hl.env("GDK_SCALE", 2)',
                "GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua",
            ),
            (
                'hl.env("GDK_SCALE", "02")',
                "GTK scale must be a whole-number string or tostring of a local whole number in monitors.lua",
            ),
            (
                "local tostring = custom\n" + OMARCHY_CONFIG,
                "GTK scale requires the unmodified tostring function in monitors.lua",
            ),
            (
                'hl.env("GDK_SCALE", "2")\nhl.env("GDK_SCALE", "1")\n',
                "Remove duplicate GDK_SCALE settings from monitors.lua",
            ),
        ]:
            with self.subTest(source=source):
                self.assertEqual(self.gtk_status(source)["error"], message)
        for source, value in [
            ('hl.env("GDK_SCALE", "3")', 3),
            ("hl.env('GDK_SCALE', '4') -- x", 4),
            ('hl.env("GDK_SCALE", "2") hl.env("OTHER", "1")', 2),
            ('hl.env("OTHER", "2")', 1),
            ('local s = 3\nhl.env("GDK_SCALE", tostring(s))', 3),
        ]:
            with self.subTest(source=source):
                self.assertEqual(self.gtk_status(source), {"base": value, "value": value, "error": ""})

    def test_gtk_scale_cannot_interrupt_a_display_trial(self):
        self.c.reset('hl.env("GDK_SCALE", "1")\n')
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        self.assertTrue(self.c.call("patch", {"id": ident, "changes": {"scale": 1.25}})["ok"])
        self.assertTrue(self.c.call("apply")["ok"])
        state = self.c.wait_phase("testing")["state"]
        reply = self.c.call("gtk-scale", {"value": 2})
        self.assertFalse(reply["ok"])
        self.assertIn("test is already running", reply["error"])
        for action in ("patch", "discard", "apply"):
            self.assertEqual(
                self.c.call(action, {"id": ident, "changes": {"x": 5}})["error"], "A display test is already running"
            )
        self.assertEqual(json.loads(self.c.gtk_environment.read_text())["systemd"], "1")
        self.assertTrue(self.c.call("revert", {"token": state["token"]})["ok"])
        self.c.wait_phase("idle")

    def test_gtk_scale_preserves_monitor_rules_and_rejects_ambiguous_settings(self):
        source = '-- hl.env("GDK_SCALE", "9")\nhl.env("GDK_SCALE", "2") -- keep this\nhl.monitor({ output = "DP-1", scale = 1.25 })\n'
        self.assertEqual(self.gtk_status(source)["value"], 2)
        changed = after(self.c, source, gtk=3)
        self.assertEqual(changed, source.replace('"2"', '"3"'))
        self.assertEqual(self.gtk_status(changed)["value"], 3)
        self.assertEqual(after(self.c, "-- no override\n", gtk=2), '-- no override\nhl.env("GDK_SCALE", "2")\n')
        self.assertEqual(after(self.c, "", gtk=2), '\nhl.env("GDK_SCALE", "2")\n')
        for invalid in [
            source + 'hl.env("GDK_SCALE", "1")\n',
            'hl.env("GDK_SCALE", tostring(scale))',
            'if docked then hl.env("GDK_SCALE", "2") end',
        ]:
            self.assertNotEqual(self.gtk_status(invalid)["error"], "")
            self.assertFalse(self.c.call("gtk-scale", {"value": 1})["ok"])
        self.c.reset(source)
        for invalid in [0, 1.5, True, "2", 5, None, 2.0]:
            reply = self.c.call("gtk-scale", {"value": invalid})
            self.assertEqual(reply["error"], "GTK scale must be 1, 2, 3, or 4", invalid)
        self.assertEqual(self.c.call("gtk-scale", {})["error"], "GTK scale must be 1, 2, 3, or 4")

    def test_gtk_scale_stages_without_touching_config_or_environment(self):
        original = 'hl.env("GDK_SCALE", "2")\n'
        self.c.reset(original, gtk="2")
        result = self.c.call("gtk-scale", {"value": 1})
        self.assertEqual(result["gtkScale"], {"base": 2, "value": 1, "error": ""})
        self.assertEqual(self.c.call("status")["gtkScale"], result["gtkScale"])
        self.assertEqual(self.c.config.read_text(), original)
        calls = self.c.calls.read_text().splitlines()
        self.assertEqual(sorted(set(calls)), ["hyprctl\tmonitors\tall\t-j"])
        # External changes must not silently replace a pending value.
        self.c.config.write_text('hl.env("GDK_SCALE", "3")\n')
        self.assertEqual(self.c.call("apply")["error"], "GTK scale changed elsewhere. Discard the draft and try again")
        self.assertEqual(self.c.call("discard")["gtkScale"]["value"], 3)
        for value in [0, 1.5, True, "2", 5]:
            self.assertFalse(self.c.call("gtk-scale", {"value": value})["ok"])
        self.assertNotIn("systemctl", self.c.calls.read_text())
        self.assertNotIn("dbus-update", self.c.calls.read_text())

    def test_missing_config_is_a_gtk_error_only(self):
        self.c.reset()
        self.c.config.unlink()
        result = self.c.call("status")
        self.assertTrue(result["ok"])
        self.assertIsNone(result["gtkScale"]["base"])
        self.assertEqual(result["gtkScale"]["error"], f"[Errno 2] No such file or directory: '{self.c.config}'")

    def test_status_reply_and_live_rows(self):
        rows = [
            monitor(
                id=1,
                refreshRate=59.951,
                availableModes=["1920x1080@60.00Hz", "1920x1080@60.00Hz", "1280x720@60.00Hz", "bogus"],
            ),
            monitor(
                "eDP-1",
                True,
                id=0,
                x=-50,
                y=-10,
                width=0,
                height=0,
                availableModes=["2880x1800@120.00Hz", "2880x1800@60.00Hz"],
            ),
        ]
        self.c.reset("", rows)
        result = self.c.call("status")
        self.assertEqual(set(result), {"ok", "state", "live", "gtkScale", "statePath"})
        self.assertEqual(result["gtkScale"], {"base": 1, "value": 1, "error": ""})
        path = Path(result["statePath"])
        self.assertEqual(path.name, "state.json")
        self.assertTrue(path.parent.name.startswith("foamy-monitor-"))
        self.assertEqual(path.parent.parent, Path(self.c.env["XDG_RUNTIME_DIR"]))
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        external, panel = result["live"]
        self.assertEqual(external["id"], "desc:Test DP-1")
        self.assertEqual(external["selector"], "desc:Test DP-1")
        self.assertEqual(external["refreshRate"], 60.0)  # snapped to the closest advertised mode
        self.assertIs(external["connected"], True)
        self.assertEqual(external["mirrorOf"], "")
        self.assertEqual((panel["width"], panel["height"], panel["refreshRate"]), (2880, 1800, 120.0))
        self.assertEqual((panel["x"], panel["y"]), (0, 0))  # disabled outputs are clamped to 0
        self.assertEqual(
            set(external),
            {
                "name",
                "make",
                "model",
                "serial",
                "scale",
                "transform",
                "disabled",
                "focused",
                "availableModes",
                "id",
                "selector",
                "description",
                "width",
                "height",
                "refreshRate",
                "connected",
                "mirrorOf",
                "x",
                "y",
            },
        )
        state = result["state"]
        self.assertEqual(state["phase"], "idle")
        self.assertEqual(state["draft"], result["live"])
        self.assertEqual(state["base"], result["live"])
        self.assertEqual(self.c.state_file(result)["revision"], state["revision"])
        # Unchanged status does not rewrite the file.
        again = self.c.call("status")
        self.assertEqual(again["state"]["revision"], state["revision"])
        # Two outputs with one description fall back to connector names.
        twins = [monitor(), monitor("DP-2", x=1920, description="Test DP-1")]
        self.c.reset("", twins)
        self.assertEqual([m["id"] for m in self.c.call("status")["live"]], ["DP-1", "DP-2"])
        # The session's state directory follows HYPRLAND_INSTANCE_SIGNATURE.
        other = self.c.call("status", extra={"HYPRLAND_INSTANCE_SIGNATURE": "another"})["statePath"]
        self.assertNotEqual(Path(other).parent, path.parent)

    def test_mirror_readback_resolves_hyprland_ids_to_connectors(self):
        rows = [monitor(id=1), monitor("eDP-1", id=0, mirrorOf="1"), monitor("HDMI-A-1", id=2, mirrorOf="none", x=1920)]
        self.c.reset("", rows)
        actual = self.c.call("status")["live"]
        self.assertEqual([m["mirrorOf"] for m in actual], ["", "DP-1", ""])

    def test_no_displays_and_hyprctl_failures_are_errors(self):
        self.c.reset("", [])
        self.assertEqual(self.c.call("status")["error"], "No connected displays")
        self.c.displays.write_text(json.dumps("not json"))
        self.assertFalse(self.c.call("status")["ok"])
        self.c.displays.write_text(json.dumps({"a": 1}))
        self.assertEqual(self.c.call("status")["error"], "No connected displays")

    def test_config_preserves_fallback_custom_fields_comments_and_environment(self):
        source = """-- hl.monitor({ output = "DP-1", scale = 9 })
hl.env("GDK_SCALE", "2")
hl.monitor({ output = "DP-1", mode = "1920x1080@60", scale = 1, vrr = 1, reserved_area = { top = 20 }, -- keep this
  transform = 0 })
hl.monitor({ output = "", mode = "preferred", scale = 1.25 })
"""
        result = after(self.c, source, patches=[("DP-1", {"scale": 1.25})])
        self.assertIn('output = "desc:Test DP-1"', result)
        self.assertIn("vrr = 1, reserved_area = { top = 20 }, -- keep this", result)
        self.assertIn('hl.env("GDK_SCALE", "2")', result)
        self.assertIn('hl.monitor({ output = "", mode = "preferred", scale = 1.25 })', result)
        self.assertIn('-- hl.monitor({ output = "DP-1", scale = 9 })', result)
        self.assertEqual(
            result.splitlines()[2],
            'hl.monitor({ output = "desc:Test DP-1", mode = "1920x1080@60.00000", '
            "scale = 1.25, vrr = 1, reserved_area = { top = 20 }, -- keep this",
        )
        self.assertEqual(result.splitlines()[3], '  transform = 0 , position = "0x0", disabled = false, mirror = "" })')
        self.assertEqual(after(self.c, result, patches=[("DP-1", {"scale": 1.25})]), result)

    def test_internal_panel_rules_use_the_connector_clamshell_reads(self):
        # omarchy-hyprland-monitor-clamshell (4.5.0) finds the internal
        # panel's scale/position with this sed match on output = "<connector>".
        def clamshell_value(source, output, key):
            code = re.sub(r"--.*$", "", source, flags=re.M)
            for line in code.splitlines():
                if re.match(r'^\s*hl\.monitor\(\{.*output\s*=\s*"' + re.escape(output) + '"', line):
                    match = re.match(r".*[{,;\s]" + key + r'\s*=\s*("[^"]*"|[^,;}\s]+)\s*([,;}].*)?$', line)
                    if match:
                        return match[1].strip('"')
            return ""

        displays = [
            monitor("eDP-1", scale=2.0, width=2880, height=1800, availableModes=["2880x1800@60.00Hz"]),
            monitor("DP-1", x=1440),
        ]
        added = after(self.c, OMARCHY_CONFIG, displays, [("eDP-1", {"scale": 1.6}), ("DP-1", {"x": 1800})])
        self.assertIn('output = "eDP-1"', added)
        self.assertIn('output = "desc:Test DP-1"', added)
        self.assertEqual(clamshell_value(added, "eDP-1", "scale"), "1.6")
        self.assertEqual(clamshell_value(added, "eDP-1", "position"), "0x0")
        self.assertEqual(
            added.splitlines()[-2],
            'hl.monitor({ output = "eDP-1", mode = "2880x1800@60.00000", '
            'position = "0x0", scale = 1.6, transform = 0, disabled = false, mirror = "" })',
        )
        self.assertEqual(
            added.splitlines()[-1],
            'hl.monitor({ output = "desc:Test DP-1", mode = "1920x1080@60.00000", '
            'position = "1800x0", scale = omarchy_monitor_scale, transform = 0, disabled = false, mirror = "" })',
        )
        # An older save keyed the panel by description; the next save moves it to the connector.
        legacy = OMARCHY_CONFIG + 'hl.monitor({ output = "desc:Test eDP-1", mode = "2880x1800@60", scale = 2 })\n'
        moved = after(self.c, legacy, displays, [("eDP-1", {"scale": 1.6}), ("DP-1", {"x": 1800})])
        self.assertNotIn("desc:Test eDP-1", moved)
        self.assertEqual(clamshell_value(moved, "eDP-1", "scale"), "1.6")
        # A mirror of the panel names the connector too.
        mirrored = after(self.c, OMARCHY_CONFIG, displays, [("DP-1", {"mirrorOf": "eDP-1"})])
        self.assertIn('mirror = "eDP-1"', mirrored)

    def test_saved_rules_keep_following_omarchy_scale_knob(self):
        # omarchy-hyprland-monitor-scaling persists by rewriting this local.
        def scaling_script(source, value):
            return re.sub(r"(?m)^local omarchy_monitor_scale = .*", f"local omarchy_monitor_scale = {value}", source)

        original = [monitor()]
        moved = [monitor(x=100)]
        move = [("DP-1", {"x": 100})]
        result = after(self.c, OMARCHY_CONFIG, original, move)
        self.assertIn("scale = omarchy_monitor_scale", result.splitlines()[-1])
        self.assertIn("local omarchy_monitor_scale = 1.6", scaling_script(result, 1.6))
        self.assertEqual(after(self.c, result, original, move), result)
        # The same rule keeps the reference on a later save that leaves the scale alone.
        self.assertIn(
            "scale = omarchy_monitor_scale", after(self.c, result, moved, [("DP-1", {"x": 200})]).splitlines()[-1]
        )
        # Choosing a scale in the panel pins it, unless it is the knob's own number.
        self.assertIn("scale = 1.25", after(self.c, result, moved, [("DP-1", {"scale": 1.25})]))
        numeric = scaling_script(OMARCHY_CONFIG, 1.25)
        self.assertIn(
            "scale = omarchy_monitor_scale", after(self.c, numeric, moved, [("DP-1", {"scale": 1.25})]).splitlines()[-1]
        )
        # Without Omarchy's knob (or with a custom catch-all) the scale stays literal.
        custom = 'hl.monitor({ output = "", mode = "preferred", scale = 1 })\n'
        self.assertIn("scale = 1,", after(self.c, custom, original, move))
        # A knob that only exists inside a comment is no knob (line or block comment).
        block = "--[[\n" + OMARCHY_CONFIG + ']]\nhl.monitor({ output = "", mode = "preferred", scale = 1 })\n'
        self.assertIn("scale = 1,", after(self.c, block, original, move).splitlines()[-1])
        level = "--[==[ old\n" + OMARCHY_CONFIG + ']==]\nhl.monitor({ output = "", scale = 1 })\n'
        self.assertIn("scale = 1,", after(self.c, level, original, move).splitlines()[-1])
        commented = "".join("-- " + line + "\n" for line in OMARCHY_CONFIG.splitlines())
        self.assertIn("scale = 1,", after(self.c, commented, original, move).splitlines()[-1])
        # Comment markers inside a string are not comments.
        quoted = OMARCHY_CONFIG.replace("-- Omarchy", 'hl.env("NOTE", "--[[ not a comment") -- Omarchy')
        self.assertIn("scale = omarchy_monitor_scale", after(self.c, quoted, original, move).splitlines()[-1])
        reassigned = OMARCHY_CONFIG + "omarchy_monitor_scale = 2\n"
        self.assertNotIn("scale = omarchy_monitor_scale,", after(self.c, reassigned, original, move).splitlines()[-1])
        # A comparison is not a reassignment; a second declaration is no single knob.
        compared = OMARCHY_CONFIG + "print(omarchy_monitor_scale == 2)\n"
        self.assertIn("scale = omarchy_monitor_scale", after(self.c, compared, original, move).splitlines()[-1])
        twice = OMARCHY_CONFIG + "local omarchy_monitor_scale = 2\n"
        self.assertIn("scale = 1,", after(self.c, twice, original, move).splitlines()[-1])
        unparsable = OMARCHY_CONFIG.replace('"auto"', "1.2.3")
        self.assertIn("scale = 1,", after(self.c, unparsable, original, move).splitlines()[-1])

    def test_numeric_knob_is_named_only_for_its_own_scale(self):
        # A runtime-only scale (no rule of its own) that differs from a numeric
        # knob must be saved as a literal: naming the knob would reload it at
        # the knob's value and fail the post-save verification (rollback).
        knob = re.sub(r"(?m)^local omarchy_monitor_scale = .*", "local omarchy_monitor_scale = 2", OMARCHY_CONFIG)
        added = after(self.c, knob, [monitor()], [("DP-1", {"x": 100})]).splitlines()[-1]
        self.assertIn("scale = 1,", added)
        self.assertNotIn("omarchy_monitor_scale", added)
        # An existing rule naming the knob, with the display at another scale now.
        existing = (
            knob
            + 'hl.monitor({ output = "desc:Test DP-1", mode = "1920x1080@60", position = "0x0", scale = omarchy_monitor_scale })\n'
        )
        rewritten = after(self.c, existing, [monitor()], [("DP-1", {"x": 100})]).splitlines()[-1]
        self.assertRegex(rewritten, r"scale = 1\s*,")
        # Equal to the knob's number: keep following it.
        two = [monitor(scale=2.0, width=3840, height=2160, availableModes=["3840x2160@60.00Hz"])]
        self.assertIn(
            "scale = omarchy_monitor_scale", after(self.c, knob, two, [("DP-1", {"x": 100})]).splitlines()[-1]
        )

    def test_saved_rules_name_no_other_global_or_automatic_values(self):
        # Audit: the scale knob is the only global a saved rule may name. Mode,
        # position, transform and mirror are always this display's literal
        # values (never "preferred"/"auto"/"highres"), and fields the panel does
        # not manage (vrr, bitdepth, cm, reserved areas) are kept, never added.
        original = [monitor(transform=1, refreshRate=120.0)]
        move = [("DP-1", {"x": 1920, "y": 40})]
        rule = after(self.c, OMARCHY_CONFIG, original, move).splitlines()[-1]
        for value in ('"preferred"', '"auto"', '"highres"', '"highrr"', "omarchy_gdk_scale"):
            self.assertNotIn(value, rule)
        self.assertIn('mode = "1920x1080@120.00000"', rule)
        self.assertIn('position = "1920x40"', rule)
        self.assertIn("transform = 1", rule)
        for field in ("vrr", "bitdepth", "cm"):
            self.assertNotIn(field, rule)
        source = (
            OMARCHY_CONFIG
            + 'hl.monitor({ output = "desc:Test DP-1", mode = "preferred", position = "auto", scale = 1, vrr = 2, bitdepth = 10, cm = "wide" })\n'
        )
        kept = after(self.c, source, original, move).splitlines()[-1]
        self.assertIn('vrr = 2, bitdepth = 10, cm = "wide"', kept)
        self.assertIn('mode = "1920x1080@120.00000"', kept)
        self.assertIn('position = "1920x40"', kept)

    def test_rule_values_are_formatted_like_the_python_helper(self):
        displays = [
            monitor("eDP-1", x=0),
            monitor("DP-1", x=1920, availableModes=["1920x1080@60.00Hz", "1920x1080@59.94Hz", "1920x1080@120.00Hz"]),
        ]
        for changes, expected in [
            ({"refreshRate": 120}, 'mode = "1920x1080@120.00000"'),
            ({"refreshRate": 59.94}, 'mode = "1920x1080@59.94000"'),
            ({"scale": 1.5}, "scale = 1.5,"),
            ({"scale": 2}, "scale = 2,"),
            ({"scale": 0.75}, "scale = 0.75,"),
            ({"x": 2000, "y": -1080}, 'position = "2000x-1080", scale = 1, transform = 0'),
            ({"transform": 3, "x": 1920}, "transform = 3"),
            ({"disabled": True}, "disabled = true"),
        ]:
            with self.subTest(changes=changes):
                rule = after(self.c, "", displays, [("DP-1", changes)]).splitlines()[-1]
                self.assertIn(expected, rule)
        # Quotes, backslashes and control characters in a description are escaped for Lua.
        odd = [monitor(description='Test "odd"\\\tpanel')]
        rule = after(self.c, "", odd, [("DP-1", {"x": 10})]).splitlines()[-1]
        self.assertIn('output = "desc:Test \\"odd\\"\\\\\\009panel"', rule)

    def test_config_rejects_ambiguous_and_dynamic_rules(self):
        for source, message in [
            ("hl.monitor({ output = output, scale = 1 })", "Monitor output must be a literal string in monitors.lua"),
            ("hl.monitor({ scale = 1 })", "Monitor output must be a literal string in monitors.lua"),
            (
                'hl.monitor({ output = "DP-1" })\nhl.monitor({ output = "desc:Test DP-1" })',
                "Duplicate rules for DP-1; remove the duplicate before saving",
            ),
            (
                'if docked then hl.monitor({ output = "DP-1" }) end',
                "Conditional monitor configuration must be edited in monitors.lua",
            ),
            ("hl.monitor(rule)", "Use literal hl.monitor({...}) rules in monitors.lua before saving"),
            ('x = 1; hl.monitor({ output = "DP-1" })', "Monitor rules must be standalone calls in monitors.lua"),
            (
                'hl.monitor({ output = "DP-1", scale = 1, scale = 2 })',
                "Duplicate monitor field; simplify monitors.lua before saving",
            ),
            ('hl.monitor({ output = "DP-1" }', "Cannot update this monitor rule in monitors.lua"),
            (
                'hl.monitor({ output = "desc:Test" })',
                "A monitor description matches multiple displays; use a unique description",
            ),
        ]:
            with self.subTest(source=source):
                reply, config = self.c.plan(source, [monitor(), monitor("DP-2", x=3840)], [("DP-1", {"x": 100})])
                self.assertIsNone(config)
                self.assertEqual(reply["error"], message)
                self.assertEqual(self.c.call("status")["state"]["phase"], "idle")
        # Rules for other displays, and unmatched ones, are left as they are.
        source = 'hl.monitor({ output = "DP-2", scale = 2 })\nhl.monitor({ output = "HDMI-A-1", scale = 3 })\n'
        result = after(self.c, source, [monitor(), monitor("DP-2", x=3840)], [("DP-1", {"x": 100})])
        self.assertTrue(result.startswith(source))

    def test_poll_preserves_dirty_fields_and_tracks_unchanged_fields(self):
        self.c.reset("")
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        self.assertTrue(self.c.call("patch", {"id": ident, "changes": {"scale": 1.25}})["ok"])
        self.c.displays.write_text(json.dumps([monitor("DP-7", x=100, description="Test DP-1")]))
        state = self.c.call("status")["state"]
        self.assertEqual(state["draft"][0]["scale"], 1.25)
        self.assertEqual(state["base"][0]["scale"], 1)
        self.assertEqual(state["draft"][0]["x"], 100)
        self.assertEqual(state["draft"][0]["name"], "DP-7")
        # Unplugged with unsaved changes: kept, marked disconnected.
        self.c.displays.write_text(json.dumps([monitor("HDMI-A-1")]))
        state = self.c.call("status")["state"]
        self.assertEqual([m["name"] for m in state["draft"]], ["HDMI-A-1", "DP-7"])
        self.assertFalse(state["draft"][1]["connected"])
        self.assertFalse(state["base"][1]["connected"])
        self.assertEqual(state["draft"][1]["scale"], 1.25)
        self.assertEqual(self.c.call("patch", {"id": ident, "changes": {"x": 1}})["error"], "Display is disconnected")
        self.assertEqual(self.c.call("apply")["error"], "Displays changed. Discard the draft and try again")
        # Discard drops the draft and the disconnected display with it.
        discarded = self.c.call("discard")
        self.assertEqual([m["name"] for m in discarded["state"]["draft"]], ["HDMI-A-1"])

    def test_patch_validation(self):
        self.c.reset("", [monitor(), monitor("eDP-1", x=1920)])
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        for changes, message in [
            ({"vrr": 1}, "Unknown display setting"),
            ({"x": 1.5}, "Invalid display setting: x"),
            ({"x": 100000}, "Invalid display setting: x"),
            ({"x": True}, "Invalid display setting: x"),
            ({"x": "5"}, "Invalid display setting: x"),
            ({"width": 0}, "Invalid display setting: width"),
            ({"scale": -1}, "Invalid display setting: scale"),
            ({"transform": 8}, "Invalid display setting: transform"),
            ({"disabled": 1}, "Invalid display setting: disabled"),
            ({"mirrorOf": "x" * 256}, "Invalid display setting: mirrorOf"),
            ({"mirrorOf": 1}, "Invalid display setting: mirrorOf"),
        ]:
            with self.subTest(changes=changes):
                self.assertEqual(self.c.call("patch", {"id": ident, "changes": changes})["error"], message)
        for request in [[], {"id": ident}, {"id": ident, "changes": []}]:
            self.assertEqual(self.c.call("patch", request)["error"], "Invalid display change")
        self.assertEqual(self.c.call("patch", {"id": "nope", "changes": {}})["error"], "Display is disconnected")
        reply = self.c.call("patch", {"id": ident, "changes": {"x": -99999, "refreshRate": 59.94, "transform": 7}})
        self.assertTrue(reply["ok"])
        draft = reply["state"]["draft"][0]
        self.assertEqual((draft["x"], draft["refreshRate"], draft["transform"]), (-99999, 59.94, 7))
        self.assertEqual(reply["state"]["error"], "")
        self.assertEqual(self.c.call("patch", {"id": ident, "changes": {"disabled": True}})["ok"], True)
        other = self.c.call("status")["state"]["draft"][1]["id"]
        self.assertEqual(
            self.c.call("patch", {"id": other, "changes": {"disabled": True}})["error"],
            "Keep at least one display enabled",
        )
        self.assertEqual(self.c.call("discard")["state"]["draft"][0]["x"], 0)
        # Invalid JSON on standard input is an error reply.
        for text in ("{nope\n", ""):
            result = self.c.run("patch", stdin=text)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stdout)["ok"])

    def test_invalid_modes_scales_overlap_and_last_display_are_rejected(self):
        live = [monitor(), monitor("eDP-1", True)]
        for changes, message in [
            ({"scale": 1.4}, "Unsupported scale for DP-1"),
            ({"scale": 9}, "Unsupported scale for DP-1"),
            ({"refreshRate": 144}, "Unsupported resolution or refresh rate for DP-1"),
            ({"width": 1280, "height": 720}, "Unsupported resolution or refresh rate for DP-1"),
            ({"disabled": True}, "Keep at least one display enabled"),
        ]:
            with self.subTest(changes=changes):
                reply, config = self.c.plan("", live, [("DP-1", changes)])
                self.assertIsNone(config)
                self.assertEqual(reply["error"], message)
        reply, _ = self.c.plan("", live, [("eDP-1", {"disabled": False})])
        self.assertEqual(reply["error"], "Displays overlap. Adjust their arrangement")
        reply, config = self.c.plan("", live, [("eDP-1", {"disabled": False, "x": 1920})])
        self.assertTrue(reply["ok"], reply)
        rotated = [monitor(), monitor("eDP-1", x=1080, transform=1)]
        reply, _ = self.c.plan("", rotated, [("DP-1", {"transform": 1})])
        self.assertTrue(reply["ok"], reply)
        reply, _ = self.c.plan("", rotated, [("DP-1", {"x": 1000})])
        self.assertEqual(reply["error"], "Displays overlap. Adjust their arrangement")
        reply, _ = self.c.plan("", [monitor(), monitor("eDP-1", x=1920)], [("eDP-1", {"mirrorOf": "HDMI-A-9"})])
        self.assertEqual(reply["error"], "Choose an enabled, non-mirrored source display")
        reply, _ = self.c.plan("", [monitor(), monitor("eDP-1", x=1920)], [("eDP-1", {"mirrorOf": "eDP-1"})])
        self.assertEqual(reply["error"], "Choose an enabled, non-mirrored source display")
        reply, _ = self.c.plan("", [monitor(), monitor("eDP-1", x=1920)], [("eDP-1", {"mirrorOf": "DP-1"})])
        self.assertTrue(reply["ok"], reply)
        self.c.reset("")
        self.assertEqual(self.c.call("apply")["error"], "No unsaved changes")

    def test_apply_preconditions(self):
        self.c.reset("")
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        self.c.call("patch", {"id": ident, "changes": {"x": 5}})
        reply = self.c.call("apply", extra={"TEST_CONFIG_ERRORS": "config error at line 3"})
        self.assertEqual(reply["error"], "Fix Hyprland configuration errors before saving")
        target = self.c.directory / "dotfiles-monitors.lua"
        target.write_text("")
        self.c.config.unlink()
        self.c.config.symlink_to(target)
        self.assertEqual(self.c.call("apply")["error"], "monitors.lua must be a machine-local file outside Stow")
        # A symlinked monitors.lua is still read for its GTK scale.
        self.assertEqual(self.c.call("status")["gtkScale"], {"base": 1, "value": 1, "error": ""})
        self.c.config.unlink()
        self.assertEqual(self.c.call("apply")["error"], f"[Errno 2] No such file or directory: '{self.c.config}'")
        # A display changed behind the draft's back.
        self.c.reset("")
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        self.c.call("patch", {"id": ident, "changes": {"x": 5}})
        self.c.displays.write_text(json.dumps([monitor(x=7, scale=2.0)]))
        state = self.c.call("status")["state"]
        self.assertEqual((state["draft"][0]["x"], state["base"][0]["x"]), (5, 0))
        self.assertEqual(state["draft"][0]["scale"], 2.0)
        self.assertEqual(
            self.c.call("apply")["error"], "Display settings changed elsewhere. Discard the draft and try again"
        )

    def test_keep_and_revert_need_the_running_trial(self):
        self.c.reset("")
        for action in ("keep", "revert"):
            self.assertEqual(self.c.call(action, {"token": ""})["error"], "This display test has ended")

    def test_usage_errors(self):
        self.c.reset("")
        for action, args in (("explode", ()), ("status", ("--bogus",)), ("worker", ("--token",))):
            result = self.c.run(action, args=args)
            self.assertEqual(result.returncode, 2, (action, args))
            self.assertTrue(result.stderr)

    def test_worker_with_a_stale_token_leaves_the_state_alone(self):
        self.c.reset("")
        before = self.c.call("status")
        result = self.c.run("worker", args=["--token", "stale"])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.c.state_file(before)["revision"], before["state"]["revision"])

    def test_rollback_enables_surviving_panel_if_external_disappears(self):
        self.c.reset("", [monitor(), monitor("eDP-1", True)])
        ident = self.c.call("status")["state"]["draft"][0]["id"]
        self.c.call("patch", {"id": ident, "changes": {"scale": 1.25}})
        self.assertTrue(self.c.call("apply")["ok"])
        self.c.wait_phase("testing")
        rows = json.loads(self.c.displays.read_text())
        self.c.displays.write_text(json.dumps([r for r in rows if r["name"] == "eDP-1"]))
        state = self.c.wait_phase("idle")["state"]
        self.assertEqual(state["error"], "A display was disconnected during the test")
        restored = json.loads(self.c.displays.read_text())
        self.assertEqual(len(restored), 1)
        self.assertEqual(restored[0]["name"], "eDP-1")
        self.assertFalse(restored[0]["disabled"])
        self.assertEqual(restored[0]["scale"], 1)
        self.assertIn(
            'hyprctl\teval\thl.monitor({ output = "eDP-1", mode = "1920x1080@60.00000", position = "0x0", '
            'scale = 1, transform = 0, disabled = false, mirror = "" })\n',
            self.c.calls.read_text(),
        )

    def test_trial_applies_sources_before_mirrors_and_disables_last(self):
        displays = [monitor("eDP-1"), monitor("DP-1", x=1920), monitor("HDMI-A-1", x=3840)]
        reply, _ = self.c.plan("", displays, [("eDP-1", {"disabled": True}), ("HDMI-A-1", {"mirrorOf": "DP-1"})])
        self.assertTrue(reply["ok"], reply)
        first = next(line for line in self.c.calls.read_text().splitlines() if line.startswith("hyprctl\teval\t"))
        outputs = re.findall(r'output = "([^"]+)"', first)
        self.assertEqual(outputs, ["DP-1", "HDMI-A-1", "eDP-1"])
        self.assertEqual(first.count("hl.monitor("), 3)
        self.assertIn(" }); hl.monitor({ ", first)


class WorkerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.c = Compositor()
        self.original = 'hl.env("GDK_SCALE", "1")\nhl.monitor({ output = "DP-1", mode = "1920x1080@60", scale = 1 })\n'
        self.c.reset(self.original)
        self.config, self.displays, self.gtk_environment = self.c.config, self.c.displays, self.c.gtk_environment
        self.token = ""

    def tearDown(self):
        self.c.cleanup()

    def call(self, action, request=None, extra=None):
        return self.c.call(action, request, extra)

    def wait_phase(self, phase, timeout=10):
        return self.c.wait_phase(phase, timeout)

    def start(self):
        state = self.call("status")["state"]
        ident = state["draft"][0]["id"]
        self.assertTrue(self.call("patch", {"id": ident, "changes": {"scale": 1.25}})["ok"])
        self.assertTrue(self.call("gtk-scale", {"value": 2})["ok"])
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text())["systemd"], "1")
        self.applied_at = time.time()
        result = self.call("apply")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["state"]["phase"], "applying")
        for hidden in ("configBefore", "configAfter", "snapshot", "gtkEnvironmentBefore"):
            self.assertNotIn(hidden, result["state"])
        self.token = result["state"]["token"]
        self.assertRegex(self.token, r"^[0-9a-f]{32}$")
        self.assertIsInstance(result["state"]["workerPid"], int)
        saved = self.c.state_file(result)
        self.assertEqual(saved["configBefore"], self.original)
        self.assertEqual(saved["gtkEnvironmentBefore"], "1")
        self.assertIs(saved["monitorChanges"], True)
        return self.wait_phase("testing")

    def test_detached_timeout_restores_live_state_without_writing_config(self):
        state = self.start()["state"]
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        # The worker set it to its own clock + 15 s, between apply and now;
        # bounds from both ends, so a slow (loaded) start can't fail it.
        self.assertGreaterEqual(state["deadline"], self.applied_at + 15 - 0.01)
        self.assertLessEqual(state["deadline"], time.time() + 15 + 0.01)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="2", systemd="2", dbus="2"))
        # All calling processes have exited; the independently running worker owns recovery.
        result = self.wait_phase("idle", 22)
        self.assertEqual(result["state"]["error"], "")
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))

    def test_worker_is_detached_in_its_own_session(self):
        ident = self.call("status")["state"]["draft"][0]["id"]
        self.call("patch", {"id": ident, "changes": {"scale": 1.25}})
        # The caller's streams and an inherited descriptor must not reach the worker.
        files = {name: self.c.directory / name for name in ("stdin", "stdout", "stderr", "inherited")}
        files["stdin"].write_text("{}\n")
        with (
            files["stdin"].open() as stdin,
            files["stdout"].open("w") as stdout,
            files["stderr"].open("w") as stderr,
            files["inherited"].open("w") as inherited,
        ):
            subprocess.run(
                helper() + ["apply"],
                stdin=stdin,
                stdout=stdout,
                stderr=stderr,
                env=self.c.env,
                pass_fds=[inherited.fileno()],
                start_new_session=True,
                timeout=15,
                check=True,
            )
        reply = json.loads(files["stdout"].read_text())
        self.assertTrue(reply["ok"], reply)
        pid = reply["state"]["workerPid"]
        self.wait_phase("testing")
        self.assertEqual(os.getsid(pid), pid)
        self.assertEqual(os.getpgid(pid), pid)
        self.assertNotEqual(os.getsid(pid), os.getsid(0))
        for fd in (0, 1, 2):
            self.assertEqual(os.readlink(f"/proc/{pid}/fd/{fd}"), "/dev/null")
        for fd in os.listdir(f"/proc/{pid}/fd"):
            try:
                target = os.readlink(f"/proc/{pid}/fd/{fd}")
            except OSError:
                continue
            self.assertNotIn(target, [str(path) for path in files.values()], f"fd {fd}")
        status = Path(f"/proc/{pid}/status").read_text()
        self.assertNotEqual(int(re.search(r"PPid:\s+(\d+)", status)[1]), os.getpid())
        self.call("revert", {"token": reply["state"]["token"]})
        self.wait_phase("idle")
        for _ in range(50):
            if not Path(f"/proc/{pid}").exists() or "zombie" in Path(f"/proc/{pid}/status").read_text():
                break
            time.sleep(0.1)
        else:
            self.fail("the worker did not exit after the revert")

    def test_terminated_worker_reverts(self):
        state = self.start()["state"]
        os.kill(state["workerPid"], 15)
        result = self.wait_phase("idle")
        self.assertEqual(result["state"]["error"], "")
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))

    # A worker that dies without its own revert (SIGKILL, the OOM killer, a
    # crash) left the trial active for good: the displays stayed on the trial
    # settings and every edit answered "A display test is already running".
    # The next command now finds the worker gone and runs the revert itself.
    RECOVERED = "The display test stopped unexpectedly. The previous settings were restored."

    def kill_worker(self, pid):
        os.kill(pid, signal.SIGKILL)
        for _ in range(200):
            try:
                if "zombie" in Path(f"/proc/{pid}/status").read_text():
                    return
            except FileNotFoundError:
                return
            time.sleep(0.05)
        self.fail(f"worker {pid} did not die")

    def edit_state(self, result, **changes):
        path = Path(result["statePath"])
        state = json.loads(path.read_text())
        state.update(changes)
        path.write_text(json.dumps(state))

    def test_killed_worker_is_reverted_by_the_next_command(self):
        state = self.start()["state"]
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        self.kill_worker(state["workerPid"])
        result = self.call("status")
        self.assertEqual(result["state"]["phase"], "idle")
        self.assertEqual(result["state"]["error"], self.RECOVERED)
        self.assertEqual(result["state"]["deadline"], 0)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(result["live"][0]["scale"], 1)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))
        self.assertEqual(result["gtkScale"]["value"], 1)
        self.assertFalse(self.call("keep", {"token": self.token})["ok"])
        # Editing works again, and the recovery ran once.
        ident = result["state"]["draft"][0]["id"]
        patched = self.call("patch", {"id": ident, "changes": {"scale": 1.5}})
        self.assertTrue(patched["ok"], patched)
        self.assertEqual(patched["state"]["error"], "")
        self.assertEqual(self.c.calls.read_text().count("hyprctl\treload"), 0)

    def test_worker_killed_while_saving_restores_monitors_lua(self):
        result = self.start()
        self.kill_worker(result["state"]["workerPid"])
        # As if it died right after writing the new monitors.lua.
        saved = self.c.state_file(result)
        self.config.write_text(saved["configAfter"])
        self.edit_state(result, phase="saving")
        reply = self.call("status")
        self.assertEqual(reply["state"]["phase"], "idle")
        self.assertEqual(reply["state"]["error"], self.RECOVERED)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertIn("hyprctl\treload\n", self.c.calls.read_text())
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)

    def test_worker_killed_after_an_external_config_edit_keeps_the_edit(self):
        result = self.start()
        self.kill_worker(result["state"]["workerPid"])
        changed = self.original + "-- edited elsewhere\n"
        self.config.write_text(changed)
        reply = self.call("status")
        self.assertEqual(reply["state"]["phase"], "idle")
        self.assertEqual(self.config.read_text(), changed)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)

    def test_a_recycled_worker_pid_does_not_hold_the_trial(self):
        result = self.start()
        self.kill_worker(result["state"]["workerPid"])
        # The pid now names another live process of this user.
        other = subprocess.Popen(["sleep", "30"])
        try:
            self.edit_state(result, workerPid=other.pid)
            reply = self.call("status")
            self.assertEqual(reply["state"]["phase"], "idle")
            self.assertEqual(reply["state"]["error"], self.RECOVERED)
            self.assertIsNone(other.poll(), "the other process is left alone")
        finally:
            other.kill()
            other.wait()

    def test_a_live_worker_keeps_its_trial(self):
        state = self.start()["state"]
        reply = self.call("status")["state"]
        # Unless the 15 s trial already ran out (a loaded machine), it is untouched.
        if time.time() < state["deadline"] - 1:
            self.assertEqual(reply["phase"], "testing")
            self.assertEqual(reply["error"], "")
        self.call("revert", {"token": self.token})  # it may have ended on its own
        self.assertEqual(self.wait_phase("idle")["state"]["error"], "")

    def test_keep_persists_description_and_readback_then_revert_stays_temporary(self):
        self.start()
        self.assertFalse(self.call("keep", {"token": "expired"})["ok"])
        self.assertFalse(self.call("apply")["ok"])
        self.assertTrue(self.call("keep", {"token": self.token})["ok"])
        state = self.wait_phase("idle")["state"]
        self.assertEqual(state["error"], "")
        self.assertEqual(state["decision"], "keep")
        self.assertIn('output = "desc:Test DP-1"', self.config.read_text())
        self.assertIn("scale = 1.25", self.config.read_text())
        self.assertIn('hl.env("GDK_SCALE", "2")', self.config.read_text())
        self.assertEqual(state["gtkScale"], {"base": 2, "value": 2})
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        backup = Path(self.c.call("status")["statePath"]).parent / "monitors.lua.backup"
        self.assertEqual(backup.read_text(), self.original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertIn("hyprctl\treload\n", self.c.calls.read_text())
        kept = self.config.read_text()
        ident = state["draft"][0]["id"]
        self.call("patch", {"id": ident, "changes": {"scale": 1}})
        self.call("gtk-scale", {"value": 1})
        self.call("apply")
        state = self.wait_phase("testing")["state"]
        self.call("revert", {"token": state["token"]})
        self.wait_phase("idle")
        self.assertEqual(self.config.read_text(), kept)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="2", systemd="2", dbus="2"))

    def test_keep_preserves_the_config_mode(self):
        self.config.chmod(0o640)
        self.start()
        self.assertTrue(self.call("keep", {"token": self.token})["ok"])
        self.assertEqual(self.wait_phase("idle")["state"]["error"], "")
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)

    def test_crlf_config_is_saved_with_newlines(self):
        self.config.write_bytes(self.original.replace("\n", "\r\n").encode())
        self.start()
        self.assertTrue(self.call("keep", {"token": self.token})["ok"])
        self.assertEqual(self.wait_phase("idle")["state"]["error"], "")
        saved = self.config.read_bytes()
        self.assertNotIn(b"\r", saved)
        self.assertIn(b'hl.env("GDK_SCALE", "2")\n', saved)

    def test_config_errors_after_save_restore_the_previous_file(self):
        self.start()
        self.c.errors.write_text("monitors.lua:3: bad rule")
        self.assertTrue(self.call("keep", {"token": self.token})["ok"])
        result = self.wait_phase("idle")
        self.assertEqual(result["state"]["error"], "monitors.lua:3: bad rule")
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(result["gtkScale"]["value"], 1)

    def test_gtk_only_keep_and_discard_preserve_monitor_rules(self):
        displays = self.displays.read_text()
        self.call("gtk-scale", {"value": 2})
        result = self.call("discard")
        self.assertEqual(result["gtkScale"], {"base": 1, "value": 1, "error": ""})
        self.assertEqual(self.config.read_text(), self.original)
        self.call("gtk-scale", {"value": 2})
        self.assertTrue(self.call("apply")["ok"])
        state = self.wait_phase("testing")["state"]
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(self.displays.read_text(), displays)
        self.call("keep", {"token": state["token"]})
        result = self.wait_phase("idle")
        self.assertEqual(result["state"]["error"], "")
        self.assertEqual(self.config.read_text(), self.original.replace('"GDK_SCALE", "1"', '"GDK_SCALE", "2"'))
        self.assertEqual(self.displays.read_text(), displays)
        self.assertIn("hyprctl\treload\tconfig-only\n", self.c.calls.read_text())
        self.assertNotIn("hyprctl\teval\thl.monitor", self.c.calls.read_text())

    def test_partial_gtk_apply_failure_restores_runtime_and_config(self):
        self.call("gtk-scale", {"value": 2})
        self.assertTrue(self.call("apply", extra={"TEST_FAIL_GTK": "2"})["ok"])
        result = self.wait_phase("idle")
        self.assertEqual(result["state"]["error"], "Session bus unavailable")
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))
        self.assertEqual(result["gtkScale"]["value"], 1)

    def test_unset_gtk_environment_is_unset_again(self):
        self.gtk_environment.write_text(json.dumps(dict(compositor="1", systemd=None, dbus="1")))
        self.call("gtk-scale", {"value": 2})
        result = self.call("apply")
        self.assertTrue(result["ok"])
        self.assertIsNone(self.c.state_file(result)["gtkEnvironmentBefore"])
        state = self.wait_phase("testing")["state"]
        self.call("revert", {"token": state["token"]})
        self.assertEqual(self.wait_phase("idle")["state"]["error"], "")
        self.assertIsNone(json.loads(self.gtk_environment.read_text())["systemd"])
        calls = self.c.calls.read_text()
        self.assertIn('hyprctl\teval\thl.env("GDK_SCALE", "2")\n', calls)
        self.assertIn("dbus-update-activation-environment\t--systemd\tGDK_SCALE=2\n", calls)
        self.assertIn("dbus-update-activation-environment\t--systemd\tGDK_SCALE=\n", calls)
        self.assertIn("systemctl\t--user\tunset-environment\tGDK_SCALE\n", calls)

    def test_omarchy_default_gtk_scale_status_discard_revert_and_keep(self):
        self.config.write_text(OMARCHY_CONFIG)
        self.gtk_environment.write_text(json.dumps(dict(compositor="2", systemd="2", dbus="2")))
        displays = self.displays.read_text()
        self.assertEqual(self.call("status")["gtkScale"], {"base": 2, "value": 2, "error": ""})
        self.assertTrue(self.call("gtk-scale", {"value": 1})["ok"])
        self.assertEqual(self.call("discard")["gtkScale"], {"base": 2, "value": 2, "error": ""})
        for decision in ("revert", "keep"):
            self.assertTrue(self.call("gtk-scale", {"value": 1})["ok"])
            self.assertEqual(self.config.read_text(), OMARCHY_CONFIG)
            self.assertTrue(self.call("apply")["ok"])
            state = self.wait_phase("testing")["state"]
            self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))
            self.assertEqual(self.config.read_text(), OMARCHY_CONFIG)
            self.assertTrue(self.call(decision, {"token": state["token"]})["ok"])
            result = self.wait_phase("idle")
            self.assertEqual(result["state"]["error"], "")
            expected = 1 if decision == "keep" else 2
            self.assertEqual(result["gtkScale"], {"base": expected, "value": expected, "error": ""})
            self.assertEqual(self.config.read_text(), OMARCHY_CONFIG.replace("= 2", f"= {expected}"))
            self.assertEqual(self.displays.read_text(), displays)
            self.assertEqual(
                json.loads(self.gtk_environment.read_text()),
                dict.fromkeys(("compositor", "systemd", "dbus"), str(expected)),
            )

    def test_external_config_edit_is_preserved_and_trial_rolls_back(self):
        self.start()
        changed = self.original + "-- edited elsewhere\n"
        self.config.write_text(changed)
        self.call("keep", {"token": self.token})
        result = self.wait_phase("idle")
        self.assertEqual(result["state"]["error"], "monitors.lua changed during the test; try again")
        self.assertEqual(self.config.read_text(), changed)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)


if __name__ == "__main__":
    unittest.main()
