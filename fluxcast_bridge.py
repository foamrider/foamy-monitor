#!/usr/bin/env python3

"""Structured, lifecycle-safe bridge between Quickshell and FluxCast."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import shutil
import subprocess
import sys
from typing import Any


PEER_LINE = re.compile(r"^\s*\[(\d+)]\s+([0-9a-fA-F:]{17})(?:\s+(.*))?$")
MAC_ADDRESS = re.compile(r"^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}$")

_child: subprocess.Popen[str] | None = None
_stop_requested = False
_stop_count = 0
_mode = ""


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), flush=True)


def parse_scan_output(output: str) -> list[dict[str, Any]]:
    peers: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None

    for raw_line in output.splitlines():
        line = raw_line.rstrip()
        match = PEER_LINE.match(line)
        if match:
            tail = (match.group(3) or "").strip()
            name = tail
            source = ""
            if tail.startswith("via "):
                name = ""
                source = tail.removeprefix("via ")
            elif " via " in tail:
                name, source = tail.rsplit(" via ", 1)

            current = {
                "index": int(match.group(1)),
                "address": match.group(2).upper(),
                "name": name.strip(),
                "source": source.strip(),
                "wfdCapable": False,
            }
            peers.append(current)
            continue

        if current is not None and "WFD capability data detected" in line:
            current["wfdCapable"] = True

    return peers


def phase_for_line(line: str) -> tuple[str, str] | None:
    if "Starting NetworkManager Wi-Fi Direct scan" in line or "Starting Wi-Fi Direct scan" in line:
        return "scanning", "Looking for the selected wireless display"
    if "Connecting to " in line:
        return "connecting", "Creating the Wi-Fi Direct connection"
    if "P2P link is activated" in line or "Waiting for TV RTSP/WFD session" in line:
        return "waiting", "Waiting for the receiver to start mirroring"
    if "PLAY accepted; media stream started" in line:
        return "casting", "Desktop and audio are being shared"
    if " ERROR:" in line or line.startswith("ERROR:"):
        return "error", line.rsplit("ERROR:", 1)[-1].strip() or "FluxCast failed"
    return None


def stop_child(_signum: int, _frame: Any) -> None:
    global _stop_count, _stop_requested
    _stop_requested = True
    _stop_count += 1
    if _mode == "cast":
        emit({"type": "phase", "phase": "stopping", "detail": "Stopping the cast cleanly"})

    child = _child
    if child is not None and child.poll() is None:
        if _stop_count == 1:
            # FluxCast handles SIGINT as KeyboardInterrupt and runs its P2P cleanup.
            child.send_signal(signal.SIGINT)
        else:
            # Only escalate after the cleanup path has had time to finish.
            child.terminate()


def fluxcast_command() -> str:
    return os.environ.get("FLUXCAST_BIN", "fluxcast")


def child_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["PYTHONUNBUFFERED"] = "1"
    return environment


def missing_packages(for_cast: bool = False) -> list[str]:
    # FluxCast owns discovery and capture fallback. Optional capture backends
    # must not block scanning or prevent it from trying another backend.
    required = [(fluxcast_command(), "fluxcast-git")]
    if for_cast:
        required.append(("ffmpeg", "ffmpeg"))
    return [package for executable, package in required if shutil.which(executable) is None]


def dependency_status(for_cast: bool = False) -> dict[str, Any]:
    missing = missing_packages(for_cast)
    return {"ok": not missing, "missingPackages": missing, "peers": [],
            "error": "Please install " + ", ".join(missing) if missing else ""}


def run_scan(timeout: int) -> int:
    global _child, _mode
    _mode = "scan"
    dependencies = dependency_status()
    if not dependencies["ok"]:
        emit(dependencies)
        return 127
    command = [fluxcast_command(), "--wfd-scan", "--wfd-timeout", str(timeout)]

    try:
        _child = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            env=child_environment(),
        )
        output, _ = _child.communicate()
    except FileNotFoundError:
        emit({"ok": False, "error": "Please install fluxcast-git", "missingPackages": ["fluxcast-git"], "peers": []})
        return 127
    except OSError as error:
        emit({"ok": False, "error": f"Could not start FluxCast: {error}", "peers": []})
        return 1

    return_code = _child.returncode
    peers = parse_scan_output(output)
    if _stop_requested:
        emit({"ok": False, "error": "Scan cancelled", "peers": []})
        return 130
    if return_code != 0:
        error_lines = [line.strip() for line in output.splitlines() if "ERROR:" in line]
        message = error_lines[-1].split("ERROR:", 1)[-1].strip() if error_lines else "Wireless display scan failed"
        emit({"ok": False, "error": message, "peers": []})
        return return_code

    emit({"ok": True, "error": "", "peers": peers})
    return 0


def run_cast(args: argparse.Namespace) -> int:
    global _child, _mode
    _mode = "cast"
    dependencies = dependency_status(for_cast=True)
    if not dependencies["ok"]:
        emit({"type": "phase", "phase": "error", "detail": dependencies["error"]})
        return 127
    peer = args.peer.upper()
    if not MAC_ADDRESS.fullmatch(peer):
        emit({"type": "phase", "phase": "error", "detail": "Invalid wireless display address"})
        return 2

    command = [
        fluxcast_command(),
        "--protocol", "wfd",
        "--wfd-peer", peer,
        "--monitor", args.monitor,
        "--output-res", args.output_res,
        "--fps", str(args.fps),
        "--bitrate", args.bitrate,
        "--wfd-timeout", str(args.timeout),
    ]
    emit({"type": "phase", "phase": "starting", "detail": "Preparing FluxCast"})

    last_error = ""
    reached_casting = False
    try:
        _child = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=child_environment(),
        )
        assert _child.stdout is not None
        for raw_line in _child.stdout:
            line = raw_line.rstrip()
            if not line:
                continue
            phase = phase_for_line(line)
            if phase is None:
                continue
            phase_name, detail = phase
            if phase_name == "casting":
                reached_casting = True
            elif phase_name == "error":
                last_error = detail
            emit({"type": "phase", "phase": phase_name, "detail": detail})
        return_code = _child.wait()
    except FileNotFoundError:
        emit({"type": "phase", "phase": "error", "detail": "Please install fluxcast-git"})
        return 127
    except OSError as error:
        emit({"type": "phase", "phase": "error", "detail": f"Could not start FluxCast: {error}"})
        return 1

    if _stop_requested:
        emit({"type": "exit", "expected": True, "code": return_code})
        return 0

    if return_code != 0:
        emit({
            "type": "phase",
            "phase": "error",
            "detail": last_error or f"FluxCast exited with code {return_code}",
        })
        emit({"type": "exit", "expected": False, "code": return_code})
        return return_code

    if reached_casting:
        emit({"type": "phase", "phase": "idle", "detail": "Cast ended"})
    else:
        emit({"type": "phase", "phase": "error", "detail": last_error or "FluxCast ended before casting started"})
    emit({"type": "exit", "expected": False, "code": return_code})
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("check", help="Check required wireless display packages")

    scan = subparsers.add_parser("scan", help="Run one bounded WFD discovery")
    scan.add_argument("--timeout", type=int, default=8, choices=range(1, 31), metavar="1-30")

    cast = subparsers.add_parser("cast", help="Start one foreground WFD session")
    cast.add_argument("--peer", required=True)
    cast.add_argument("--monitor", required=True)
    cast.add_argument("--output-res", default="1920x1080")
    cast.add_argument("--fps", type=int, default=30, choices=range(1, 121), metavar="1-120")
    cast.add_argument("--bitrate", default="4M")
    cast.add_argument("--timeout", type=int, default=8, choices=range(1, 31), metavar="1-30")
    return parser.parse_args()


def main() -> int:
    signal.signal(signal.SIGTERM, stop_child)
    signal.signal(signal.SIGINT, stop_child)
    args = parse_args()
    if args.command == "check":
        emit(dependency_status())
        return 0
    if args.command == "scan":
        return run_scan(args.timeout)
    return run_cast(args)


if __name__ == "__main__":
    raise SystemExit(main())
