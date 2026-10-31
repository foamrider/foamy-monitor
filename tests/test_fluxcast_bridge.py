#!/usr/bin/env python3

import importlib.util
import io
import json
from pathlib import Path
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from unittest.mock import Mock, patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "fluxcast_bridge.py"
SPEC = importlib.util.spec_from_file_location("fluxcast_bridge", MODULE_PATH)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class FluxCastBridgeTest(unittest.TestCase):
    def test_scan_output_becomes_stable_peer_records(self):
        output = """
[FluxCast WFD] Wi-Fi Direct peer(s):
  [0] 7a:2d:91:40:0b:ce  Living Room TV via NetworkManager
      WFD capability data detected
  [1] 02:11:22:33:44:55 via wpa_cli
"""

        self.assertEqual(
            BRIDGE.parse_scan_output(output),
            [
                {
                    "index": 0,
                    "address": "7A:2D:91:40:0B:CE",
                    "name": "Living Room TV",
                    "source": "NetworkManager",
                    "wfdCapable": True,
                },
                {
                    "index": 1,
                    "address": "02:11:22:33:44:55",
                    "name": "",
                    "source": "wpa_cli",
                    "wfdCapable": False,
                },
            ],
        )

    def test_no_peer_message_produces_empty_list(self):
        self.assertEqual(
            BRIDGE.parse_scan_output("[FluxCast WFD] No Wi-Fi Direct peers found."),
            [],
        )

    def test_fluxcast_log_lines_map_to_honest_phases(self):
        self.assertEqual(
            BRIDGE.phase_for_line("[FluxCast WFD] P2P link is activated; waiting for RTSP session..."),
            ("waiting", "Waiting for the receiver to start mirroring"),
        )
        self.assertEqual(
            BRIDGE.phase_for_line("[FluxCast WFD RTSP] PLAY accepted; media stream started."),
            ("casting", "Desktop and audio are being shared"),
        )
        self.assertEqual(
            BRIDGE.phase_for_line("[FluxCast WFD] ERROR: receiver rejected the session"),
            ("error", "receiver rejected the session"),
        )
        self.assertIsNone(BRIDGE.phase_for_line("unrelated diagnostic"))

    def test_missing_packages_are_reported_before_starting_a_scan(self):
        with patch.object(BRIDGE.shutil, "which", side_effect=lambda name: None if name in ("fluxcast", "ffmpeg") else "/usr/bin/" + name):
            status = BRIDGE.dependency_status()
        self.assertFalse(status["ok"])
        self.assertEqual(status["missingPackages"], ["fluxcast-git"])
        self.assertEqual(status["error"], "Please install fluxcast-git")

    def test_discovery_runs_without_capture_dependencies(self):
        child = Mock(returncode=0)
        child.communicate.return_value = ("[FluxCast WFD] No Wi-Fi Direct peers found.", None)
        output = io.StringIO()
        try:
            with patch.object(BRIDGE.shutil, "which", side_effect=lambda name: "/usr/bin/fluxcast" if name == "fluxcast" else None), \
                 patch.object(BRIDGE.subprocess, "Popen", return_value=child) as popen, redirect_stdout(output):
                self.assertEqual(BRIDGE.run_scan(8), 0)
            self.assertEqual(popen.call_args.args[0], ["fluxcast", "--wfd-scan", "--wfd-timeout", "8"])
            self.assertEqual(json.loads(output.getvalue()), {"ok": True, "error": "", "peers": []})
        finally:
            BRIDGE._child = None
            BRIDGE._mode = ""

    def test_cast_allows_fluxcast_capture_fallback(self):
        with patch.object(BRIDGE.shutil, "which", side_effect=lambda name: None if name == "wf-recorder" else "/usr/bin/" + name):
            self.assertTrue(BRIDGE.dependency_status(for_cast=True)["ok"])
        with patch.object(BRIDGE.shutil, "which", side_effect=lambda name: None if name == "ffmpeg" else "/usr/bin/" + name):
            self.assertEqual(BRIDGE.dependency_status(for_cast=True)["missingPackages"], ["ffmpeg"])

    def test_stop_uses_fluxcast_cleanup_signal_before_escalating(self):
        class FakeChild:
            def __init__(self):
                self.signals = []
                self.terminated = False

            def poll(self):
                return None

            def send_signal(self, child_signal):
                self.signals.append(child_signal)

            def terminate(self):
                self.terminated = True

        child = FakeChild()
        BRIDGE._child = child
        BRIDGE._mode = "cast"
        BRIDGE._stop_count = 0
        BRIDGE._stop_requested = False

        try:
            with redirect_stdout(io.StringIO()):
                BRIDGE.stop_child(signal.SIGTERM, None)
                BRIDGE.stop_child(signal.SIGTERM, None)

            # The escalation reaches FluxCast's whole process group.
            self.assertEqual(child.signals, [signal.SIGINT, signal.SIGTERM])
            self.assertTrue(BRIDGE._stop_requested)
        finally:
            BRIDGE._child = None
            BRIDGE._mode = ""
            BRIDGE._stop_count = 0
            BRIDGE._stop_requested = False


    def test_fluxcast_stops_when_the_bridge_is_killed(self):
        # Quickshell destroys a running Process with SIGKILL, which the bridge
        # cannot handle; FluxCast must still get its cleanup signal (SIGINT).
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            marker = base / "fluxcast.log"
            fake = base / "fluxcast"
            fake.write_text("""#!/usr/bin/python3
import os, signal, sys, time
log = open(sys.argv[0] + ".log", "a", buffering=1)
def stop(number, _frame):
    log.write("signal %d\\n" % number)
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
log.write("started %d %d\\n" % (os.getpid(), os.getpgid(0)))
print("Connecting to peer", flush=True)
while True:
    time.sleep(0.05)
""")
            fake.chmod(0o755)
            (base / "ffmpeg").symlink_to("/usr/bin/true")
            env = dict(os.environ, FLUXCAST_BIN=str(fake), PATH=f"{base}:/usr/bin")
            bridge = subprocess.Popen([sys.executable, str(MODULE_PATH), "cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1"],
                                      stdout=subprocess.PIPE, text=True, env=env)
            try:
                for _ in range(100):
                    if marker.exists() and "started" in marker.read_text():
                        break
                    time.sleep(0.05)
                started = marker.read_text().split()
                self.assertEqual(started[0], "started")
                self.assertEqual(started[1], started[2], "FluxCast leads its own process group")
                bridge.kill()
                bridge.wait(timeout=5)
                for _ in range(100):
                    if "signal" in marker.read_text():
                        break
                    time.sleep(0.05)
                self.assertIn("signal %d" % signal.SIGINT, marker.read_text())
            finally:
                if bridge.poll() is None:
                    bridge.kill()
                bridge.stdout.close()
                try:
                    os.killpg(int(started[2]), signal.SIGKILL)
                except (OSError, NameError, IndexError, ValueError):
                    pass


if __name__ == "__main__":
    unittest.main()
