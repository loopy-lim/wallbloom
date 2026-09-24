#!/usr/bin/env python3
"""Isolated gravity (cover/contain/stretch) acceptance for the Wallbloom engine.

Requirements proven in one run, against a purpose-built aspect-mismatch fixture:
  1. wall.json gravity is parsed and applied (contain default from the manifest).
  2. active.json gravity override switches cover/contain/stretch instantly:
     same engine windows, no hotswap restart, no readiness rebuild, <= 3 s.
  3. Invalid override values fall back to cover; removing the override returns
     to the wallpkg default.
  4. Captured window pixels differ measurably between all three modes.

The engine runs with an isolated HOME + WALLBLOOM_SUPPORT_DIR; user state is
snapshotted and verified unchanged. PASS is decided by captured pixels only.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1]).resolve()
EVIDENCE = Path(tempfile.mkdtemp(prefix="wallbloom-gravity-evidence-"))
REPORT = {"provider": os.getenv("PI_PROVIDER"), "model": os.getenv("PI_MODEL"),
          "worker_pid": os.getpid(), "session_id": os.getenv("PI_SESSION_ID"),
          "session_file": os.getenv("PI_SESSION_FILE"), "identity_source": "worker environment (not routing attestation)",
          "selection_driver": "isolated active.json atomic gravity override (not Tauri GUI)",
          "fixture": "240x480 portrait clip, top quarter red, rest blue; aspect-mismatch vs landscape screen",
          "metrics_legend": "24x24 RGB downscale; black=near-black px, red=red px, blue=blue px fractions",
          "captures": [], "switches": [], "readiness": []}

EXPECTED = {
    # discriminator thresholds on a landscape screen (w/h >= 1.2)
    "contain": lambda m: m["black"] > 0.4 and m["blue"] > 0.1,
    "cover": lambda m: m["black"] < 0.1 and m["red"] < 0.05 and m["blue"] > 0.8,
    "stretch": lambda m: m["black"] < 0.1 and 0.15 < m["red"] < 0.4,
}


def snapshot(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def window_ids(pid, helper):
    source = helper.with_suffix(".swift")
    source.write_text('''import AppKit\nimport CoreGraphics\nlet pid = Int32(CommandLine.arguments[1])!\nlet windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]\nfor window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {\n  if let id = window[kCGWindowNumber as String] { print(id) }\n}\n''')
    if not helper.exists():
        subprocess.run(["swiftc", str(source), "-o", str(helper)], check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = subprocess.run([str(helper), str(pid)], check=True, capture_output=True, text=True, timeout=15)
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def capture(window_id, destination):
    result = subprocess.run(["screencapture", "-x", "-l", str(window_id), str(destination)], capture_output=True, text=True, timeout=15)
    if result.returncode != 0 or not destination.is_file():
        raise RuntimeError(f"screencapture failed: {result.stderr.strip()}")


def metrics(image):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(image), "-vf", "scale=24:24", "-frames:v", "1",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True, timeout=15).stdout
    n = len(raw) // 3
    counts = {"black": 0, "red": 0, "blue": 0}
    for i in range(n):
        r, g, b = raw[3 * i], raw[3 * i + 1], raw[3 * i + 2]
        if r < 30 and g < 30 and b < 30:
            counts["black"] += 1
        elif r > 150 and g < 100 and b < 100:
            counts["red"] += 1
        elif b > 150 and r < 100 and g < 100:
            counts["blue"] += 1
    return {key: value / n for key, value in counts.items()}


def pixel_delta(left, right):
    def pixels(image):
        return subprocess.run(["ffmpeg", "-v", "error", "-i", str(image), "-vf", "scale=24:24", "-frames:v", "1",
                               "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True, check=True, timeout=15).stdout
    a, b = pixels(left), pixels(right)
    if len(a) != len(b) or not a:
        return 0.0
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def atomic_write(path, payload):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as state:
        json.dump(payload, state)
        state.flush()
        os.fsync(state.fileno())
    os.replace(temporary, path)


def run():
    if platform.system() != "Darwin":
        raise RuntimeError("macOS/WindowServer required")
    user_active = Path.home() / "Library/Application Support/Wallbloom/active.json"
    before = snapshot(user_active)
    REPORT["user_active_sha256_before"] = before
    process = None
    master = None
    try:
        with tempfile.TemporaryDirectory(prefix="wallbloom-gravity-home-") as directory:
            home = Path(directory)
            support = home / "Library/Application Support/Wallbloom"
            env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       WALLBLOOM_SUPPORT_DIR=str(support))
            probe = home / "probe.swift"
            probe.write_text('''import Foundation\nimport AppKit\nimport CoreGraphics\nprint(FileManager.default.homeDirectoryForCurrentUser.path)\nlet screen = NSScreen.screens.first\nlet frame = screen?.frame ?? .zero\nprint("screens=\\(NSScreen.screens.count)")\nprint("aspect=\\(frame.width == 0 ? 0 : frame.width / frame.height)")\nprint("screen_capture=\\(CGPreflightScreenCaptureAccess())")\n''')
            with (EVIDENCE / "build.log").open("w") as log:
                subprocess.run(["swiftc", str(probe), "-o", str(home / "probe")], stdout=log, stderr=log, check=True, timeout=120)
                result = subprocess.run([str(home / "probe")], env=env, capture_output=True, text=True, check=True, timeout=15)
                (EVIDENCE / "preflight.log").write_text(result.stdout + result.stderr)
                REPORT["preflight"] = result.stdout.splitlines()
                lines = result.stdout.splitlines()
                if not lines or Path(lines[0]).resolve() != home.resolve():
                    raise RuntimeError("Foundation home isolation failed; engine NOT launched")
                if "screens=0" in result.stdout:
                    raise RuntimeError("no NSScreen available; engine NOT launched")
                aspect = float(lines[2].split("=")[1]) if len(lines) > 2 else 0.0
                REPORT["screen_aspect"] = aspect
                if aspect < 1.2:
                    raise RuntimeError(f"landscape screen expected for fixed thresholds, aspect={aspect}")
                if "screen_capture=0" in result.stdout:
                    raise RuntimeError("screen capture permission missing")
                subprocess.run(["swiftc", "-O", "-framework", "AppKit", "-framework", "AVFoundation",
                                str(ROOT / "engine/main.swift"), "-o", str(home / "engine")], stdout=log, stderr=log, check=True, timeout=180)
                REPORT["engine_source_sha256"] = snapshot(ROOT / "engine/main.swift")
            # Aspect-mismatch fixture: portrait 240x480, top quarter red, rest blue.
            fixture = home / "fixtures"
            fixture.mkdir()
            video = fixture / "fixture.mp4"
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "lavfi", "-i", "color=c=red:s=240x480:r=24:d=6",
                            "-f", "lavfi", "-i", "color=c=blue:s=240x360:r=24:d=6",
                            "-filter_complex", "[0]crop=240:120:0:0[top];[top][1]vstack=inputs=2",
                            "-pix_fmt", "yuv420p", "-c:v", "libx264", str(video)], check=True, timeout=60)
            package = support / "library" / "gravity-fixture"
            package.mkdir(parents=True)
            shutil.copyfile(video, package / "entry.mp4")
            (package / "wall.json").write_text(json.dumps(
                {"spec": 0.2, "id": "gravity-fixture", "title": "Gravity Fixture", "type": "video",
                 "entry": "entry.mp4", "gravity": "contain"}))
            REPORT["fixture_sha256"] = snapshot(package / "entry.mp4")
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen([str(home / "engine")], cwd=home, env=env, stdout=slave, stderr=slave)
            finally:
                os.close(slave)
            REPORT["isolated_engine_pid"] = process.pid
            helper = home / "window-ids"
            pending = b""
            ack_lines = []

            def drain_log(timeout=0.0):
                nonlocal pending
                if select.select([master], [], [], timeout)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        return
                    if not chunk:
                        return
                    (EVIDENCE / "engine.log").open("ab").write(chunk)
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        text = line.decode(errors="replace")
                        if text.startswith("WALLBLOOM_APPLY "):
                            ack_lines.append(json.loads(text[len("WALLBLOOM_APPLY "):]))

            def wait_for_ack(package_path, deadline_s=17):
                start = time.monotonic()
                while time.monotonic() - start < deadline_s and process.poll() is None:
                    drain_log(0.1)
                    for event in ack_lines:
                        if event["id"] == str(package_path) and event["event"] == "ack":
                            return time.monotonic() - start
                raise RuntimeError("engine readiness ACK not observed for initial apply")

            def observe(expected_mode, index, label):
                """Poll captures until pixels match the expected mode; <= 3 s switch budget."""
                start = time.monotonic()
                deadline = start + 3.5
                last = None
                while time.monotonic() < deadline and process.poll() is None:
                    image = EVIDENCE / f"{index}-{label}.png"
                    ids = window_ids(process.pid, helper)
                    if not ids:
                        raise RuntimeError("CGWindowList returned no engine windows")
                    capture(ids[0], image)
                    last = metrics(image)
                    if EXPECTED[expected_mode](last):
                        elapsed = time.monotonic() - start
                        return {"matched": True, "window_id": ids[0], "screenshot": str(image),
                                "metrics": last, "switch_ms": elapsed * 1000, "within_3s": elapsed <= 3.0}
                    time.sleep(0.15)
                return {"matched": False, "screenshot": str(EVIDENCE / f"{index}-{label}.png"),
                        "metrics": last, "within_3s": False}

            # Phase 1: initial apply without override -> wall.json gravity (contain).
            atomic_write(support / "active.json", {"spec": 0.2, "active": str(package), "paused": False})
            ack_seconds = wait_for_ack(package)
            REPORT["readiness"].append({"package": package.name, "ack_ms": ack_seconds * 1000})
            initial = observe("contain", 0, "default-contain")
            initial["mode"] = "contain (wall.json default)"
            initial["source"] = "wall.json gravity, no active.json override"
            REPORT["switches"].append(initial)
            window_id = initial.get("window_id")
            prior = Path(initial["screenshot"])

            # Phases 2-5: gravity-only active.json edits on the SAME active package.
            # (expected mode, payload, label, mode-actually-changes-from-previous)
            phases = [
                ("stretch", {"spec": 0.2, "active": str(package), "paused": False, "gravity": "stretch"}, "stretch", True),
                ("cover", {"spec": 0.2, "active": str(package), "paused": False, "gravity": "cover"}, "cover", True),
                ("cover", {"spec": 0.2, "active": str(package), "paused": False, "gravity": "diagonal"}, "invalid-cover-fallback", False),
                ("contain", {"spec": 0.2, "active": str(package), "paused": False}, "override-removed", True),
            ]
            for index, (expected_mode, payload, label, mode_changed) in enumerate(phases, start=1):
                drain_log(0)
                acks_before = len(ack_lines)
                atomic_write(support / "active.json", payload)
                outcome = observe(expected_mode, index, label)
                outcome.update(mode=expected_mode, payload_gravity=payload.get("gravity", None),
                               source="active.json gravity override" if "gravity" in payload else "override removed",
                               mode_changed_from_previous=mode_changed)
                drain_log(0)
                outcome["readiness_events_during_switch"] = len(ack_lines) - acks_before
                outcome["same_window_as_initial"] = outcome.get("window_id") == window_id
                current = Path(outcome["screenshot"])
                outcome["pixel_delta_from_previous"] = pixel_delta(prior, current)
                prior = current
                REPORT["switches"].append(outcome)

            time.sleep(0.5)
            drain_log(0)
            REPORT["final_window_ids"] = window_ids(process.pid, helper)
            REPORT["total_readiness_events"] = len(ack_lines)
            switches = REPORT["switches"]
            instant_ok = all(item["matched"] and item["within_3s"] for item in switches)
            no_restart_ok = (switches[0].get("window_id") is not None
                              and all(item.get("same_window_as_initial") for item in switches[1:])
                              and all(item["readiness_events_during_switch"] == 0 for item in switches[1:])
                              and len(ack_lines) == 1)
            pixels_changed = all(item["pixel_delta_from_previous"] > 8 for item in switches[1:]
                                 if item["mode_changed_from_previous"])
            REPORT["gravity_status"] = "PASS" if instant_ok and no_restart_ok and pixels_changed else "FAIL"
            REPORT["evidence_summary"] = {
                "instant_switch_all_modes": instant_ok,
                "no_restart_single_ack": no_restart_ok,
                "captured_pixel_changed_between_modes": pixels_changed,
            }
            REPORT["blockers"] = []
            if REPORT["gravity_status"] != "PASS":
                REPORT["blockers"] = [f"gravity acceptance failed: {REPORT['evidence_summary']}"]
            return 0 if REPORT["gravity_status"] == "PASS" else 2
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
        REPORT["captures"] = sorted(path.name for path in EVIDENCE.glob("*.png"))
        REPORT["user_active_sha256_after"] = snapshot(user_active)
        REPORT["user_state_unchanged"] = before == snapshot(user_active)
        if not REPORT["user_state_unchanged"]:
            raise RuntimeError("user active.json changed during test; inspect evidence (test never writes user state)")


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
        print(f"PASS: gravity cover/contain/stretch captured pixel switches within 3 s, no restart. Evidence: {EVIDENCE}")
    else:
        print(f"FAIL: gravity mode acceptance NOT VERIFIED. Evidence: {EVIDENCE}", file=sys.stderr)
sys.exit(code)
