#!/usr/bin/env python3
"""Exercise the real helper/worker boundary with an isolated compositor double."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PLUGIN))
import display_transaction as backend
from display_config import gtk_scale_setting, update_config, update_gtk_scale


def monitor(name="DP-1", disabled=False):
    return dict(name=name, id="desc:Test " + name, selector="desc:Test " + name,
                description="Test " + name, make="Test", model=name, serial=name,
                width=1920, height=1080, refreshRate=60.0, scale=1.0, transform=0,
                x=0, y=0, disabled=disabled, mirrorOf="", focused=not disabled,
                connected=True, availableModes=["1920x1080@60.00Hz", "1920x1080@120.00Hz"])


class DisplayModelTests(unittest.TestCase):
    def test_gtk_scale_cannot_interrupt_a_display_trial(self):
        with tempfile.TemporaryDirectory() as directory:
            store = backend.Store(Path(directory))
            store.write(dict(phase="testing", base=[monitor()], draft=[monitor()]))
            with patch.object(backend, "live_monitors", return_value=[monitor()]), patch.object(backend, "apply_gtk_scale") as update:
                with self.assertRaisesRegex(ValueError, "test is already running"):
                    backend.command(store, "gtk-scale", {"value": 1})
                update.assert_not_called()

    def test_gtk_scale_preserves_monitor_rules_and_rejects_ambiguous_settings(self):
        source = '-- hl.env("GDK_SCALE", "9")\nhl.env("GDK_SCALE", "2") -- keep this\nhl.monitor({ output = "DP-1", scale = 1.25 })\n'
        self.assertEqual(gtk_scale_setting(source)[0], 2)
        changed = update_gtk_scale(source, 3)
        self.assertEqual(changed, source.replace('"2"', '"3"'))
        self.assertEqual(update_gtk_scale(changed, 3), changed)
        self.assertEqual(gtk_scale_setting(update_gtk_scale("-- no override\n", 1))[0], 1)
        for invalid in [source + 'hl.env("GDK_SCALE", "1")\n',
                        'hl.env("GDK_SCALE", tostring(scale))',
                        'if docked then hl.env("GDK_SCALE", "2") end']:
            with self.assertRaises(ValueError):
                update_gtk_scale(invalid, 1)
        for invalid in [0, 1.5, True, "2", 5]:
            with self.assertRaises(ValueError):
                update_gtk_scale(source, invalid)

    def test_gtk_scale_stages_without_touching_config_or_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "monitors.lua"
            original = 'hl.env("GDK_SCALE", "2")\n'
            config.write_text(original)
            store = backend.Store(Path(directory) / "state")
            with patch.object(backend, "CONFIG", config), patch.object(backend, "live_monitors", return_value=[monitor()]), patch.object(backend, "run") as run:
                result = backend.command(store, "gtk-scale", {"value": 1})
                self.assertEqual(result["gtkScale"], {"base": 2, "value": 1, "error": ""})
                self.assertEqual(backend.command(store, "status", {})["gtkScale"], result["gtkScale"])
                self.assertEqual(config.read_text(), original)
                run.assert_not_called()
                # External changes must not silently replace a pending value.
                config.write_text('hl.env("GDK_SCALE", "3")\n')
                with self.assertRaisesRegex(ValueError, "changed elsewhere"):
                    backend.command(store, "apply", {})
                self.assertEqual(backend.command(store, "discard", {})["gtkScale"]["value"], 3)
                for value in [0, 1.5, True, "2", 5]:
                    with self.assertRaises(ValueError):
                        backend.command(store, "gtk-scale", {"value": value})

    def test_mirror_readback_resolves_hyprland_ids_to_connectors(self):
        rows = [dict(monitor(), id=1), dict(monitor("eDP-1"), id=0, mirrorOf="1")]
        with patch.object(backend, "run", return_value=json.dumps(rows)):
            actual = backend.live_monitors()
        self.assertEqual(actual[1]["mirrorOf"], "DP-1")

    def test_config_preserves_fallback_custom_fields_comments_and_environment(self):
        source = '''-- hl.monitor({ output = "DP-1", scale = 9 })
hl.env("GDK_SCALE", "2")
hl.monitor({ output = "DP-1", mode = "1920x1080@60", scale = 1, vrr = 1, reserved_area = { top = 20 }, -- keep this
  transform = 0 })
hl.monitor({ output = "", mode = "preferred", scale = 1.25 })
'''
        changed = monitor()
        changed["scale"] = 1.25
        result = update_config(source, [changed])
        self.assertIn('output = "desc:Test DP-1"', result)
        self.assertIn('vrr = 1, reserved_area = { top = 20 }, -- keep this', result)
        self.assertIn('hl.env("GDK_SCALE", "2")', result)
        self.assertIn('hl.monitor({ output = "", mode = "preferred", scale = 1.25 })', result)
        self.assertIn('-- hl.monitor({ output = "DP-1", scale = 9 })', result)
        self.assertEqual(update_config(result, [changed]), result)

    def test_config_rejects_ambiguous_and_dynamic_rules(self):
        for source in ['hl.monitor({ output = output, scale = 1 })',
                       'hl.monitor({ output = "DP-1" })\nhl.monitor({ output = "desc:Test DP-1" })',
                       'if docked then hl.monitor({ output = "DP-1" }) end']:
            with self.assertRaises(ValueError):
                update_config(source, [monitor()])

    def test_poll_preserves_dirty_fields_and_tracks_unchanged_fields(self):
        original = monitor()
        draft = dict(original, scale=1.25)
        state = dict(phase="idle", base=[original], draft=[draft])
        live = dict(original, x=100, name="DP-7")
        backend.reconcile(state, [live])
        self.assertEqual(state["draft"][0]["scale"], 1.25)
        self.assertEqual(state["base"][0]["scale"], 1)
        self.assertEqual(state["draft"][0]["x"], 100)
        self.assertEqual(state["draft"][0]["name"], "DP-7")
        backend.reconcile(state, [])
        self.assertFalse(state["draft"][0]["connected"])
        self.assertEqual(state["draft"][0]["scale"], 1.25)

    def test_invalid_modes_scales_overlap_and_last_display_are_rejected(self):
        live = [monitor(), monitor("eDP-1", True)]
        for changes in [{"scale": 1.4}, {"refreshRate": 144}, {"disabled": True}]:
            draft = copy.deepcopy(live)
            draft[0].update(changes)
            with self.assertRaises(ValueError):
                backend.validate(draft, live)
        overlapping = copy.deepcopy(live)
        overlapping[1]["disabled"] = False
        with self.assertRaisesRegex(ValueError, "overlap"):
            backend.validate(overlapping, live)
        overlapping[1]["x"] = 1920
        backend.validate(overlapping, live)

    def test_rollback_enables_surviving_panel_if_external_disappears(self):
        snapshot = [monitor(), monitor("eDP-1", True)]
        with patch.object(backend, "live_monitors", return_value=[snapshot[1]]), patch.object(backend, "apply") as apply, patch.object(backend, "wait_verified"):
            backend.rollback(snapshot)
        restored = apply.call_args.args[0][0]
        self.assertEqual(restored["name"], "eDP-1")
        self.assertFalse(restored["disabled"])


FAKE_HYPRCTL = r'''#!/usr/bin/env python3
import json, os, re, sys
from pathlib import Path
path=Path(os.environ['TEST_DISPLAYS'])
rows=json.loads(path.read_text())
args=sys.argv[1:]
if args[0]=='monitors': print(json.dumps(rows))
elif args[0]=='configerrors': print('')
elif args[0] in ('eval','reload'):
    if args[0]=='eval': source=args[1]
    else: source=(Path(os.environ['XDG_CONFIG_HOME'])/'hypr/monitors.lua').read_text()
    env_path=Path(os.environ['TEST_GTK_ENV'])
    environment=json.loads(env_path.read_text())
    gtk=re.search(r'hl\.env\("GDK_SCALE",\s*"(\d+)"\)',source)
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
'''


FAKE_ENVIRONMENT = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
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
'''


class WorkerIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="display-transaction-test-")
        self.directory = Path(self.temp.name)
        (self.directory / "bin").mkdir()
        executable = self.directory / "bin/hyprctl"
        executable.write_text(FAKE_HYPRCTL)
        executable.chmod(0o700)
        for name in ("systemctl", "dbus-update-activation-environment"):
            executable = self.directory / "bin" / name
            executable.write_text(FAKE_ENVIRONMENT)
            executable.chmod(0o700)
        self.config = self.directory / "config/hypr/monitors.lua"
        self.config.parent.mkdir(parents=True)
        self.original = 'hl.env("GDK_SCALE", "1")\nhl.monitor({ output = "DP-1", mode = "1920x1080@60", scale = 1 })\n'
        self.config.write_text(self.original)
        self.displays = self.directory / "displays.json"
        self.displays.write_text(json.dumps([monitor()]))
        self.gtk_environment = self.directory / "gtk-environment.json"
        self.gtk_environment.write_text(json.dumps(dict(compositor="1", systemd="1", dbus="1")))
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.directory / "runtime"),
                        XDG_CONFIG_HOME=str(self.directory / "config"),
                        HYPRLAND_INSTANCE_SIGNATURE="isolated-test", TEST_DISPLAYS=str(self.displays),
                        TEST_GTK_ENV=str(self.gtk_environment),
                        PATH=str(self.directory / "bin") + os.pathsep + os.environ["PATH"])
        self.token = ""

    def tearDown(self):
        # Let the detached worker finish before deleting its state directory.
        try:
            state = self.call("status")["state"]
            if state["phase"] == "testing":
                self.call("revert", {"token": state["token"]})
            if state["phase"] in backend.ACTIVE:
                self.wait_phase("idle", 7)
        finally:
            self.temp.cleanup()

    def call(self, action, request=None):
        result = subprocess.run([sys.executable, str(PLUGIN / "display_transaction.py"), action],
                                input=json.dumps(request or {}) + "\n", text=True, capture_output=True,
                                env=self.env, timeout=8)
        return json.loads(result.stdout)

    def wait_phase(self, phase, timeout=7):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.call("status")
            self.assertTrue(result["ok"], result)
            if result["state"]["phase"] == phase:
                return result
            time.sleep(.1)
        self.fail(f"Did not reach {phase}: {result}")

    def start(self):
        state = self.call("status")["state"]
        ident = state["draft"][0]["id"]
        self.assertTrue(self.call("patch", {"id": ident, "changes": {"scale": 1.25}})["ok"])
        self.assertTrue(self.call("gtk-scale", {"value": 2})["ok"])
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text())["systemd"], "1")
        result = self.call("apply")
        self.assertTrue(result["ok"], result)
        self.token = result["state"]["token"]
        return self.wait_phase("testing")

    def test_detached_timeout_restores_live_state_without_writing_config(self):
        state = self.start()["state"]
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        self.assertLessEqual(state["deadline"] - time.time(), 15)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="2", systemd="2", dbus="2"))
        # All calling processes have exited; the independently running worker owns recovery.
        result = self.wait_phase("idle", 19)
        self.assertEqual(result["state"]["error"], "")
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))

    def test_keep_persists_description_and_readback_then_revert_stays_temporary(self):
        self.start()
        self.assertFalse(self.call("keep", {"token": "expired"})["ok"])
        self.assertFalse(self.call("apply")["ok"])
        self.assertTrue(self.call("keep", {"token": self.token})["ok"])
        state = self.wait_phase("idle")["state"]
        self.assertEqual(state["error"], "")
        self.assertIn('output = "desc:Test DP-1"', self.config.read_text())
        self.assertIn('scale = 1.25', self.config.read_text())
        self.assertIn('hl.env("GDK_SCALE", "2")', self.config.read_text())
        self.assertEqual(state["gtkScale"], {"base": 2, "value": 2})
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        kept = self.config.read_text()
        ident=state["draft"][0]["id"]
        self.call("patch", {"id": ident, "changes": {"scale": 1}})
        self.call("gtk-scale", {"value": 1})
        self.call("apply")
        state=self.wait_phase("testing")["state"]
        self.call("revert", {"token": state["token"]})
        self.wait_phase("idle")
        self.assertEqual(self.config.read_text(), kept)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1.25)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="2", systemd="2", dbus="2"))

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

    def test_partial_gtk_apply_failure_restores_runtime_and_config(self):
        self.env["TEST_FAIL_GTK"] = "2"
        self.call("gtk-scale", {"value": 2})
        self.assertTrue(self.call("apply")["ok"])
        result = self.wait_phase("idle")
        self.assertIn("Session bus unavailable", result["state"]["error"])
        self.assertEqual(self.config.read_text(), self.original)
        self.assertEqual(json.loads(self.gtk_environment.read_text()), dict(compositor="1", systemd="1", dbus="1"))
        self.assertEqual(result["gtkScale"]["value"], 1)

    def test_external_config_edit_is_preserved_and_trial_rolls_back(self):
        self.start()
        changed = self.original + '-- edited elsewhere\n'
        self.config.write_text(changed)
        self.call("keep", {"token": self.token})
        result = self.wait_phase("idle")
        self.assertIn("changed during", result["state"]["error"])
        self.assertEqual(self.config.read_text(), changed)
        self.assertEqual(json.loads(self.displays.read_text())[0]["scale"], 1)


if __name__ == '__main__':
    unittest.main()
