#!/usr/bin/env python3

import importlib.util
import io
import json
from pathlib import Path
import signal
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

            self.assertEqual(child.signals, [signal.SIGINT])
            self.assertTrue(child.terminated)
            self.assertTrue(BRIDGE._stop_requested)
        finally:
            BRIDGE._child = None
            BRIDGE._mode = ""
            BRIDGE._stop_count = 0
            BRIDGE._stop_requested = False


if __name__ == "__main__":
    unittest.main()
