#!/usr/bin/env python3
"""Black-box tests of the FluxCast bridge: check, scan and cast.

The bridge runs as a process with a fake `fluxcast` (and `ffmpeg`) on a PATH
that holds nothing else, so the installed FluxCast never runs and nothing is
cast. FOAMY_HELPER is the helper's argv prefix as a JSON list starting with
an absolute path (default: this machine's
bin/<arch>/foamy-monitor-helper), e.g.
  FOAMY_HELPER='["/abs/bin/aarch64/foamy-monitor-helper"]' python3 -I tests/test_fluxcast_bridge.py
"""

import json
import os
import platform
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[1]


def helper():
    if os.environ.get("FOAMY_HELPER"):
        prefix = json.loads(os.environ["FOAMY_HELPER"])
        if not prefix or not Path(prefix[0]).is_absolute():
            raise SystemExit("FOAMY_HELPER must be a JSON list starting with an absolute path")
        return prefix
    return [str(PLUGIN / "bin" / platform.machine() / "foamy-monitor-helper")]


# FAKE_MODE: "print" (write FAKE_OUTPUT, exit FAKE_EXIT), "hold" (write it,
# then run until SIGINT or SIGTERM) or "stubborn" (like hold, but only a
# SIGTERM ends it; it also starts a child in its process group that logs the
# SIGTERM it gets).
FAKE_FLUXCAST = r"""
import os, signal, subprocess, sys, time
log = os.environ["FAKE_LOG"]
def write(*parts):
    with open(log, "a") as stream:
        stream.write("\t".join(str(p) for p in parts) + "\n")
write("argv", *sys.argv[1:])
write("env", os.environ.get("PYTHONUNBUFFERED", "-"))
write("ids", os.getpid(), os.getpgid(0), os.getsid(0), os.getppid())
mode = os.environ.get("FAKE_MODE", "print")
def on_signal(number, _frame):
    write("signal", number)
    if mode == "stubborn" and number == signal.SIGINT:
        return
    sys.exit(0)
signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)
if mode == "stubborn":
    subprocess.Popen([sys.executable, "-I", "-c", "import signal, sys, time\n"
        "def stop(*_):\n with open(sys.argv[1], 'a') as s: s.write('grandchild\\tterm\\n')\n sys.exit(0)\n"
        "signal.signal(signal.SIGTERM, stop)\nwhile True: time.sleep(0.05)\n", log])
output = os.environ.get("FAKE_OUTPUT")
if output:
    sys.stdout.write(open(output, encoding="utf-8").read())
    sys.stdout.flush()
write("ready")
if mode in ("hold", "stubborn"):
    while True:
        time.sleep(0.05)
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
"""

PEERS = """
[FluxCast WFD] Wi-Fi Direct peer(s):
  [0] 7a:2d:91:40:0b:ce  Living Room TV via NetworkManager
      WFD capability data detected
  [1] 02:11:22:33:44:55 via wpa_cli
  [12] AA:BB:CC:DD:EE:FF Bedroom via Box via wpa_cli
  [x] 11:22:33:44:55:66 not a peer
  [3] 11:22:33:44:55 too short
"""


class Bridge(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fluxcast-bridge-test-")
        self.directory = Path(self.temp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.log = self.directory / "fluxcast.log"
        self.output = self.directory / "output.txt"
        self.fake = self.bin / "fluxcast"
        self.fake.write_text(f"#!{sys.executable} -I\n" + FAKE_FLUXCAST)
        self.fake.chmod(0o755)
        (self.bin / "ffmpeg").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "ffmpeg").chmod(0o755)
        self.env = {
            "PATH": str(self.bin),
            "HOME": str(self.directory),
            "FAKE_LOG": str(self.log),
            "FAKE_OUTPUT": str(self.output),
            "LANG": "C.UTF-8",
        }
        self.output.write_text("")
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            for stream in (process.stdout, process.stderr):
                if stream:
                    stream.close()
        # Stop any fake left behind (its own session) before the directory goes.
        for line in self.lines("ids"):
            try:
                os.killpg(int(line[2]), signal.SIGKILL)
            except (OSError, ValueError):
                pass
        self.temp.cleanup()

    def lines(self, kind=None):
        text = self.log.read_text() if self.log.exists() else ""
        rows = [line.split("\t") for line in text.splitlines()]
        return [row for row in rows if kind is None or row[0] == kind]

    def wait_for(self, kind, count=1, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if len(self.lines(kind)) >= count:
                return self.lines(kind)
            time.sleep(0.02)
        self.fail(f"fluxcast did not log {kind!r} x{count}: {self.lines()}")

    def run_bridge(self, *args, **extra):
        env = dict(self.env, **extra)
        result = subprocess.run(helper() + list(args), capture_output=True, text=True, env=env, timeout=20)
        return result

    def start(self, *args, **extra):
        env = dict(self.env, **extra)
        process = subprocess.Popen(
            helper() + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env
        )
        self.processes.append(process)
        return process

    def events(self, text):
        return [json.loads(line) for line in text.splitlines() if line.strip()]

    # ---- check ------------------------------------------------------------
    def test_check_reports_missing_packages(self):
        result = self.run_bridge("check")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "missingPackages": [], "peers": [], "error": ""})
        self.fake.unlink()
        result = self.run_bridge("check")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            json.loads(result.stdout),
            {"ok": False, "missingPackages": ["fluxcast-git"], "peers": [], "error": "Please install fluxcast-git"},
        )
        self.assertEqual(result.stdout.count("\n"), 1)
        # Not executable counts as missing; a directory is not an executable.
        self.fake.mkdir()
        self.assertFalse(json.loads(self.run_bridge("check").stdout)["ok"])
        self.fake.rmdir()
        self.fake.write_text("#!/bin/sh\n")
        self.fake.chmod(0o644)
        self.assertFalse(json.loads(self.run_bridge("check").stdout)["ok"])
        self.assertEqual(self.lines(), [])

    def test_fluxcast_bin_overrides_the_command(self):
        elsewhere = self.directory / "elsewhere"
        elsewhere.mkdir()
        self.fake.rename(elsewhere / "fluxcast-custom")
        self.assertEqual(json.loads(self.run_bridge("check").stdout)["missingPackages"], ["fluxcast-git"])
        custom = str(elsewhere / "fluxcast-custom")
        self.assertTrue(json.loads(self.run_bridge("check", FLUXCAST_BIN=custom).stdout)["ok"])
        self.output.write_text("[FluxCast WFD] No Wi-Fi Direct peers found.\n")
        result = self.run_bridge("scan", FLUXCAST_BIN=custom)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "error": "", "peers": []})
        self.assertEqual(self.lines("argv"), [["argv", "--wfd-scan", "--wfd-timeout", "8"]])
        # A bare name is looked up on PATH.
        (self.bin / "fluxcast-other").symlink_to(custom)
        self.assertTrue(json.loads(self.run_bridge("check", FLUXCAST_BIN="fluxcast-other").stdout)["ok"])

    # ---- scan -------------------------------------------------------------
    def test_scan_output_becomes_stable_peer_records(self):
        self.output.write_text(PEERS)
        result = self.run_bridge("scan", "--timeout", "8")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "ok": True,
                "error": "",
                "peers": [
                    {
                        "index": 0,
                        "address": "7A:2D:91:40:0B:CE",
                        "name": "Living Room TV",
                        "source": "NetworkManager",
                        "wfdCapable": True,
                    },
                    {"index": 1, "address": "02:11:22:33:44:55", "name": "", "source": "wpa_cli", "wfdCapable": False},
                    {
                        "index": 12,
                        "address": "AA:BB:CC:DD:EE:FF",
                        "name": "Bedroom via Box",
                        "source": "wpa_cli",
                        "wfdCapable": False,
                    },
                ],
            },
        )
        self.assertEqual(result.stdout.count("\n"), 1)
        self.assertEqual(self.lines("argv"), [["argv", "--wfd-scan", "--wfd-timeout", "8"]])

    def test_scan_details(self):
        self.output.write_text(
            "  [7] 7a:2d:91:40:0b:ce\r\n  [8] 7a:2d:91:40:0b:cf  Kitchen  \n"
            "WFD capability data detected\n  [9] 7a:2d:91:40:0b:d0 via æøå\n"
        )
        result = self.run_bridge("scan", "--timeout", "3")
        self.assertEqual(self.lines("argv"), [["argv", "--wfd-scan", "--wfd-timeout", "3"]])
        self.assertEqual(
            json.loads(result.stdout)["peers"],
            [
                {"index": 7, "address": "7A:2D:91:40:0B:CE", "name": "", "source": "", "wfdCapable": False},
                {"index": 8, "address": "7A:2D:91:40:0B:CF", "name": "Kitchen", "source": "", "wfdCapable": True},
                {"index": 9, "address": "7A:2D:91:40:0B:D0", "name": "", "source": "æøå", "wfdCapable": False},
            ],
        )
        self.assertIn("æøå", result.stdout)  # not \u-escaped

    def test_no_peer_message_produces_empty_list(self):
        self.output.write_text("[FluxCast WFD] No Wi-Fi Direct peers found.")
        result = self.run_bridge("scan")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "error": "", "peers": []})
        self.assertEqual(self.lines("argv"), [["argv", "--wfd-scan", "--wfd-timeout", "8"]])

    def test_scan_failure_reports_the_last_error_and_exit_code(self):
        self.output.write_text(
            "[FluxCast WFD] ERROR: first\nnoise\n  [FluxCast WFD] ERROR: no p2p device: ERROR: x  \n"
        )
        result = self.run_bridge("scan", FAKE_EXIT="4")
        self.assertEqual(result.returncode, 4)
        self.assertEqual(json.loads(result.stdout), {"ok": False, "error": "no p2p device: ERROR: x", "peers": []})
        self.output.write_text("[0] 7a:2d:91:40:0b:ce TV\n")
        result = self.run_bridge("scan", FAKE_EXIT="3")
        self.assertEqual(result.returncode, 3)
        # FluxCast's own 127 is passed on as 1.
        result = self.run_bridge("scan", FAKE_EXIT="127")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertEqual(json.loads(result.stdout), {"ok": False, "error": "Wireless display scan failed", "peers": []})

    def test_missing_packages_are_reported_before_starting_a_scan(self):
        self.fake.unlink()
        result = self.run_bridge("scan", "--timeout", "8")
        # Not 126/127: the shell reads those as "no helper for this CPU".
        self.assertEqual(result.returncode, 69)
        self.assertEqual(
            json.loads(result.stdout),
            {"ok": False, "missingPackages": ["fluxcast-git"], "peers": [], "error": "Please install fluxcast-git"},
        )

    def test_discovery_runs_without_capture_dependencies(self):
        (self.bin / "ffmpeg").unlink()
        self.output.write_text("[FluxCast WFD] No Wi-Fi Direct peers found.")
        result = self.run_bridge("scan", "--timeout", "8")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "error": "", "peers": []})

    def test_scan_cancel_stops_fluxcast_with_sigint(self):
        bridge = self.start("scan", "--timeout", "8", FAKE_MODE="hold")
        self.wait_for("ready")
        bridge.send_signal(signal.SIGTERM)
        stdout, _ = bridge.communicate(timeout=10)
        self.assertEqual(bridge.returncode, 130)
        self.assertEqual(json.loads(stdout), {"ok": False, "error": "Scan cancelled", "peers": []})
        self.assertEqual(self.lines("signal"), [["signal", str(int(signal.SIGINT))]])

    def test_fluxcast_runs_in_its_own_session_with_unbuffered_python(self):
        bridge = self.start("scan", FAKE_MODE="hold")
        ids = self.wait_for("ids")[0]
        pid, pgid, sid, ppid = (int(v) for v in ids[1:])
        self.assertEqual(pid, pgid, "FluxCast leads its own process group")
        self.assertEqual(pid, sid, "FluxCast leads its own session")
        self.assertEqual(ppid, bridge.pid)
        self.assertEqual(self.lines("env"), [["env", "1"]])
        bridge.send_signal(signal.SIGINT)
        bridge.communicate(timeout=10)
        self.assertEqual(bridge.returncode, 130)

    # ---- cast -------------------------------------------------------------
    def cast(self, *args, **extra):
        return self.run_bridge("cast", "--peer", "aa:bb:cc:dd:ee:ff", "--monitor", "DP-1", *args, **extra)

    def test_cast_argv_and_honest_phases(self):
        self.output.write_text(
            "[FluxCast WFD] Starting NetworkManager Wi-Fi Direct scan\n"
            "\n"
            "[FluxCast WFD] Connecting to AA:BB:CC:DD:EE:FF\r"
            "unrelated diagnostic\n"
            "[FluxCast WFD] P2P link is activated; waiting for RTSP session...\r\n"
            "[FluxCast WFD RTSP] PLAY accepted; media stream started.\n"
        )
        result = self.cast("--output-res", "1280x720", "--fps", "60", "--bitrate", "8M", "--timeout", "12")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.lines("argv"),
            [
                [
                    "argv",
                    "--protocol",
                    "wfd",
                    "--wfd-peer",
                    "AA:BB:CC:DD:EE:FF",
                    "--monitor",
                    "DP-1",
                    "--output-res",
                    "1280x720",
                    "--fps",
                    "60",
                    "--bitrate",
                    "8M",
                    "--wfd-timeout",
                    "12",
                ]
            ],
        )
        self.assertEqual(
            self.events(result.stdout),
            [
                {"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"},
                {"type": "phase", "phase": "scanning", "detail": "Looking for the selected wireless display"},
                {"type": "phase", "phase": "connecting", "detail": "Creating the Wi-Fi Direct connection"},
                {"type": "phase", "phase": "waiting", "detail": "Waiting for the receiver to start mirroring"},
                {"type": "phase", "phase": "casting", "detail": "Desktop and audio are being shared"},
                {"type": "phase", "phase": "idle", "detail": "Cast ended"},
                {"type": "exit", "expected": False, "code": 0},
            ],
        )

    def test_cast_defaults(self):
        result = self.cast()
        self.assertEqual(
            self.lines("argv"),
            [
                [
                    "argv",
                    "--protocol",
                    "wfd",
                    "--wfd-peer",
                    "AA:BB:CC:DD:EE:FF",
                    "--monitor",
                    "DP-1",
                    "--output-res",
                    "1920x1080",
                    "--fps",
                    "30",
                    "--bitrate",
                    "4M",
                    "--wfd-timeout",
                    "8",
                ]
            ],
        )
        self.assertEqual(
            self.events(result.stdout)[-2:],
            [
                {"type": "phase", "phase": "error", "detail": "FluxCast ended before casting started"},
                {"type": "exit", "expected": False, "code": 0},
            ],
        )
        self.assertEqual(result.returncode, 0)

    def test_cast_failure_keeps_the_last_error(self):
        self.output.write_text(
            "Waiting for TV RTSP/WFD session\n[FluxCast WFD] ERROR: receiver rejected the session\nERROR:\n"
        )
        result = self.cast(FAKE_EXIT="3")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(
            self.events(result.stdout),
            [
                {"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"},
                {"type": "phase", "phase": "waiting", "detail": "Waiting for the receiver to start mirroring"},
                {"type": "phase", "phase": "error", "detail": "receiver rejected the session"},
                {"type": "phase", "phase": "error", "detail": "FluxCast failed"},
                {"type": "phase", "phase": "error", "detail": "FluxCast failed"},
                {"type": "exit", "expected": False, "code": 3},
            ],
        )
        self.output.write_text("")
        result = self.cast(FAKE_EXIT="5")
        self.assertEqual(
            self.events(result.stdout)[-2:],
            [
                {"type": "phase", "phase": "error", "detail": "FluxCast exited with code 5"},
                {"type": "exit", "expected": False, "code": 5},
            ],
        )

    def test_cast_allows_fluxcast_capture_fallback_but_needs_ffmpeg(self):
        result = self.cast()
        self.assertEqual(
            self.events(result.stdout)[0], {"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"}
        )
        (self.bin / "ffmpeg").unlink()
        self.log.unlink()
        result = self.cast()
        self.assertEqual(result.returncode, 69)
        self.assertEqual(
            self.events(result.stdout), [{"type": "phase", "phase": "error", "detail": "Please install ffmpeg"}]
        )
        self.fake.unlink()
        result = self.cast()
        self.assertEqual(
            self.events(result.stdout),
            [{"type": "phase", "phase": "error", "detail": "Please install fluxcast-git, ffmpeg"}],
        )
        self.assertEqual(self.lines(), [])

    def test_cast_validates_its_arguments(self):
        result = self.run_bridge("cast", "--peer", "not-a-mac", "--monitor", "DP-1")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            self.events(result.stdout),
            [{"type": "phase", "phase": "error", "detail": "Invalid wireless display address"}],
        )
        for args in (
            ["cast", "--monitor", "DP-1"],
            ["cast", "--peer", "AA:BB:CC:DD:EE:FF"],
            ["cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1", "--fps", "0"],
            ["cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1", "--fps", "121"],
            ["cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1", "--timeout", "31"],
            ["scan", "--timeout", "0"],
            ["scan", "--timeout", "x"],
            ["scan", "extra"],
            ["nothing"],
            [],
        ):
            with self.subTest(args=args):
                result = self.run_bridge(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
        self.assertEqual(self.lines(), [])

    def test_stop_uses_fluxcast_cleanup_signal_before_escalating(self):
        bridge = self.start("cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1", FAKE_MODE="stubborn")
        self.wait_for("ready")
        bridge.send_signal(signal.SIGTERM)
        self.wait_for("signal")
        self.assertEqual(self.lines("signal"), [["signal", str(int(signal.SIGINT))]])
        self.assertEqual(self.lines("grandchild"), [])
        time.sleep(0.2)
        bridge.send_signal(signal.SIGTERM)
        stdout, _ = bridge.communicate(timeout=10)
        # The escalation reaches FluxCast's whole process group.
        self.assertEqual(
            self.lines("signal"), [["signal", str(int(signal.SIGINT))], ["signal", str(int(signal.SIGTERM))]]
        )
        self.wait_for("grandchild")
        self.assertEqual(bridge.returncode, 0)
        self.assertEqual(
            self.events(stdout),
            [
                {"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"},
                {"type": "phase", "phase": "stopping", "detail": "Stopping the cast cleanly"},
                {"type": "phase", "phase": "stopping", "detail": "Stopping the cast cleanly"},
                {"type": "exit", "expected": True, "code": 0},
            ],
        )

    def test_fluxcast_stops_when_the_bridge_is_killed(self):
        # Quickshell destroys a running Process with SIGKILL, which the bridge
        # cannot handle; FluxCast must still get its cleanup signal (SIGINT).
        self.output.write_text("Connecting to peer\n")
        bridge = self.start("cast", "--peer", "AA:BB:CC:DD:EE:FF", "--monitor", "DP-1", FAKE_MODE="hold")
        self.wait_for("ready")
        bridge.kill()
        bridge.wait(timeout=5)
        self.wait_for("signal")
        self.assertEqual(self.lines("signal"), [["signal", str(int(signal.SIGINT))]])

    def test_bridge_stops_fluxcast_when_its_parent_dies(self):
        # The shell itself dies: the bridge gets SIGTERM (its own parent-death
        # signal) and stops FluxCast through the normal path.
        events = self.directory / "events.jsonl"
        parent = subprocess.Popen(
            [
                sys.executable,
                "-I",
                "-c",
                "import subprocess, sys, time\n"
                "with open(sys.argv[1], 'w') as out:\n"
                "    subprocess.Popen(sys.argv[2:], stdout=out)\n"
                "time.sleep(60)\n",
                str(events),
                *helper(),
                "cast",
                "--peer",
                "AA:BB:CC:DD:EE:FF",
                "--monitor",
                "DP-1",
            ],
            env=dict(self.env, FAKE_MODE="hold"),
        )
        self.processes.append(parent)
        self.wait_for("ready")
        parent.kill()
        parent.wait(timeout=5)
        self.wait_for("signal")
        self.assertEqual(self.lines("signal"), [["signal", str(int(signal.SIGINT))]])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and '"exit"' not in events.read_text():
            time.sleep(0.05)
        self.assertEqual(self.events(events.read_text())[-1], {"type": "exit", "expected": True, "code": 0})


if __name__ == "__main__":
    unittest.main()
