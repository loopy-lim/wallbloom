#!/usr/bin/env python3
"""Isolated engine test requiring independently visible A/B frame evidence."""
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import pty
import select
import signal
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1]).resolve()
EVIDENCE = Path(tempfile.mkdtemp(prefix="wallbloom-hotswap-evidence-"))
REPORT = {"provider": os.getenv("PI_PROVIDER"), "model": os.getenv("PI_MODEL"),
          "worker_pid": os.getpid(), "session_id": os.getenv("PI_SESSION_ID"),
          "session_file": os.getenv("PI_SESSION_FILE"), "identity_source": "worker environment (not routing attestation)",
          "readiness": [], "visible_frame": "NOT VERIFIED",
          "selection_driver": "isolated active.json atomic replacement (not Tauri GUI)",
          "fixture_pixels": "ffmpeg-generated visibly distinct solid-color A/B clips"}


def installed_processes():
    result = subprocess.run(["pgrep", "-fl", "^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom"], capture_output=True, text=True)
    return result.stdout.strip()


def snapshot(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def window_ids(pid, helper):
    source = helper.with_suffix(".swift")
    source.write_text('''import AppKit\nimport CoreGraphics\nlet pid = Int32(CommandLine.arguments[1])!\nlet windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]\nfor window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {\n  if let id = window[kCGWindowNumber as String] { print(id) }\n}\n''')
    if not helper.exists():
        subprocess.run(["swiftc", str(source), "-o", str(helper)], check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run([str(helper), str(pid)], check=True, capture_output=True, text=True, timeout=15)
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def pixels(image):
    result = subprocess.run(["ffmpeg", "-v", "error", "-i", str(image), "-vf", "scale=24:24", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True, timeout=15)
    return result.stdout


def pixel_delta(left, right):
    a, b = pixels(left), pixels(right)
    if len(a) != len(b) or not a:
        return 0
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def run():
    if platform.system() != "Darwin":
        raise RuntimeError("macOS/WindowServer required")
    user_active = Path.home() / "Library/Application Support/Wallbloom/active.json"
    before = snapshot(user_active)
    installed = installed_processes()
    REPORT["installed_processes_before"] = installed
    REPORT["user_active_sha256_before"] = before
    process = None
    master = None
    try:
        with tempfile.TemporaryDirectory(prefix="wallbloom-native-home-") as directory:
            home = Path(directory)
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            # Foundation may ignore HOME on macOS. Prove its effective home before
            # starting the unmodified engine; never fall back to the real home.
            probe = home / "probe.swift"
            probe.write_text('''import Foundation
import AppKit
import ApplicationServices
print(FileManager.default.homeDirectoryForCurrentUser.path)
print("screens=\\(NSScreen.screens.count)")
print("screen_capture=\\(CGPreflightScreenCaptureAccess())")
print("accessibility=\\(AXIsProcessTrusted())")
''')
            with (EVIDENCE / "build.log").open("w") as log:
                subprocess.run(["swiftc", str(probe), "-o", str(home / "probe")], stdout=log, stderr=log, check=True, timeout=120)
                result = subprocess.run([str(home / "probe")], env=env, capture_output=True, text=True, check=True, timeout=15)
                (EVIDENCE / "preflight.log").write_text(result.stdout + result.stderr)
                REPORT["preflight"] = result.stdout.splitlines()
                if not result.stdout.splitlines() or Path(result.stdout.splitlines()[0]).resolve() != home.resolve():
                    raise RuntimeError("Foundation home isolation failed; engine NOT launched")
                if "screens=0" in result.stdout:
                    raise RuntimeError("no NSScreen available; engine NOT launched")
                subprocess.run(["swiftc", "-O", "-framework", "AppKit", "-framework", "AVFoundation", str(ROOT / "engine/main.swift"), "-o", str(home / "engine")], stdout=log, stderr=log, check=True, timeout=180)
                REPORT["engine_source_sha256"] = snapshot(ROOT / "engine/main.swift")
                subprocess.run(["swiftc", str(ROOT / "ui/scripts/probe-player.swift"), "-o", str(home / "player-probe")], stdout=log, stderr=log, check=True, timeout=120)
            # Observe template vs actual looper item without altering engine code.
            with (EVIDENCE / "player-probe.json").open("w") as output, (EVIDENCE / "player-probe.stderr").open("w") as errors:
                diagnostic = subprocess.run([str(home / "player-probe"), str(ROOT / "sample-hevc.mp4")], env=env, stdout=output, stderr=errors, timeout=15)
            REPORT["player_probe_exit"] = diagnostic.returncode
            probe_result = json.loads((EVIDENCE / "player-probe.json").read_text())
            REPORT["player_probe"] = {key: value for key, value in probe_result.items() if key != "samples"}
            app_root = home / "Library/Application Support/Wallbloom"
            packages = []
            colors = [("fixture-a", "red"), ("fixture-b", "blue")]
            fixture_dir = home / "fixtures"
            fixture_dir.mkdir()
            for name, color in colors:
                video = fixture_dir / f"{name}.mp4"
                subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"color=c={color}:s=640x360:r=24:d=6", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(video)], check=True, timeout=60)
                package = app_root / "library" / name
                package.mkdir(parents=True)
                shutil.copyfile(video, package / "entry.mp4")
                (package / "wall.json").write_text(json.dumps({"spec": 0.2, "id": name, "title": name, "type": "video", "entry": "entry.mp4"}))
                packages.append(package)
            REPORT["fixture_sha256"] = [snapshot(package / "entry.mp4") for package in packages]
            if REPORT["fixture_sha256"][0] == REPORT["fixture_sha256"][1]:
                raise RuntimeError("A/B fixtures are byte-identical")
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen([str(home / "engine")], cwd=home, env=env, stdout=slave, stderr=slave)
            finally:
                os.close(slave)
            REPORT["isolated_engine_pid"] = process.pid
            pending = b""
            REPORT["transitions"] = []
            helper = home / "window-ids"
            prior_capture = None
            with (EVIDENCE / "engine.log").open("wb") as log:
                for index, package in enumerate([*packages, packages[0]]):
                    start = time.monotonic()
                    temporary = app_root / "active.json.tmp"
                    with temporary.open("w") as state:
                        json.dump({"spec": 0.2, "active": str(package), "paused": False}, state)
                        state.flush()
                        os.fsync(state.fileno())
                    os.replace(temporary, app_root / "active.json")
                    measurement = {"package": package.name, "selection_monotonic": start, "atomic_replace_ms": (time.monotonic() - start) * 1000}
                    REPORT["readiness"].append(measurement)
                    matched = False
                    while time.monotonic() - start < 17 and process.poll() is None and not matched:
                        if not select.select([master], [], [], 0.1)[0]:
                            continue
                        try:
                            chunk = os.read(master, 65536)
                        except OSError:
                            break
                        if not chunk:
                            break
                        log.write(chunk)
                        log.flush()
                        pending += chunk
                        while b"\n" in pending:
                            line, pending = pending.split(b"\n", 1)
                            text = line.decode(errors="replace")
                            if not text.startswith("WALLBLOOM_APPLY "):
                                continue
                            event = json.loads(text[len("WALLBLOOM_APPLY "):])
                            if event["id"] == str(package):
                                elapsed = time.monotonic() - start
                                measurement.update(event=event, observed_ms=elapsed * 1000,
                                                   engine_event_ms=(event["monotonicSeconds"] - start) * 1000,
                                                   within_3s=event["event"] == "ack" and elapsed <= 3)
                                matched = True
                    if not matched:
                        measurement.update(error="no matching engine ACK/failure within 17s", within_3s=False)
                    try:
                        ids = window_ids(process.pid, helper)
                        if not ids:
                            raise RuntimeError("CGWindowList returned no engine windows")
                        image = EVIDENCE / f"{index}-{package.name}-window.png"
                        capture = subprocess.run(["screencapture", "-x", "-l", ids[0], str(image)], capture_output=True, text=True, timeout=15)
                        if capture.returncode != 0 or not image.is_file():
                            raise RuntimeError(f"screencapture failed: {capture.stderr.strip()}")
                        measurement.update(window_id=ids[0], screenshot=str(image))
                        rgb = pixels(image)
                        means = [sum(rgb[channel::3]) / (len(rgb) // 3) for channel in range(3)]
                        expected_channel = 0 if package.name == "fixture-a" else 2
                        measurement["captured_rgb_mean"] = means
                        if means[expected_channel] < 100 or any(means[expected_channel] - means[c] < 80 for c in range(3) if c != expected_channel):
                            raise RuntimeError(f"capture does not display expected fixture color: {means}")
                        if prior_capture:
                            delta = pixel_delta(prior_capture, image)
                            elapsed = (time.monotonic() - start) * 1000
                            transition = {"from": str(prior_capture), "to": str(image), "pixel_delta_mean": delta, "visible_change_ms": elapsed, "within_3s": delta > 8 and elapsed <= 3000}
                            REPORT["transitions"].append(transition)
                            measurement["visible_change"] = transition
                        prior_capture = image
                    except Exception as error:
                        measurement["capture_error"] = str(error)
            # ACK is corroborating evidence only; captured pixel change determines PASS.
            REPORT["readiness_status"] = "PASS" if len(REPORT["transitions"]) == 2 and all(item["within_3s"] for item in REPORT["transitions"]) and all(item.get("within_3s") for item in REPORT["readiness"]) else "FAIL"
            REPORT["visible_frame"] = "PASS" if REPORT["readiness_status"] == "PASS" else "FAIL"
            REPORT["blockers"] = [] if REPORT["readiness_status"] == "PASS" else ["No qualifying captured A-to-B visible pixel change within 3 seconds; inspect screenshots and per-package capture_error."]
            REPORT["timing_semantics"] = "First qualifying captured frame, including capture/pixel analysis overhead; conservative upper bound, not exact presentation timestamp."
            REPORT["gui_verification"] = "Separate verify-native.sh real WebView harness; engine timing uses atomic selection, not GUI click-to-frame latency."
            REPORT["blocker"] = " ".join(REPORT["blockers"])
            return 0 if REPORT["readiness_status"] == "PASS" else 2
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            REPORT["isolated_engine_stopped"] = process.poll() is not None
        if master is not None:
            os.close(master)
        REPORT["installed_processes_after"] = installed_processes()
        REPORT["user_active_sha256_after"] = snapshot(user_active)
        REPORT["user_state_unchanged"] = before == snapshot(user_active) and installed == REPORT["installed_processes_after"]
        if not REPORT["user_state_unchanged"]:
            raise RuntimeError("user state/process changed during test; inspect evidence (test never writes user state)")


def interrupted(signum, _frame):
    raise RuntimeError(f"interrupted by signal {signum}; stopping isolated engine")


signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
started = time.monotonic()
code = 2
try:
    code = run()
except Exception as error:
    REPORT["blocker"] = str(error)
finally:
    REPORT.update(exit_code=code, elapsed_ms=(time.monotonic() - started) * 1000)
    (EVIDENCE / "result.json").write_text(json.dumps(REPORT, indent=2) + "\n")
    print(json.dumps(REPORT, indent=2))
    if code == 0:
        print(f"PASS: captured A-to-B and B-to-A visible pixel transitions within 3 seconds. Evidence: {EVIDENCE}")
    else:
        print(f"FAIL: 3-second visible screen transition NOT VERIFIED. Evidence: {EVIDENCE}", file=sys.stderr)
sys.exit(code)
