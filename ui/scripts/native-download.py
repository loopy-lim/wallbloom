#!/usr/bin/env python3
"""Loopback fixture driving actual Rust commands with a live Tauri AppHandle."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

root, evidence = map(Path, sys.argv[1:])
body = (root / "sample-hevc.mp4").read_bytes()
requests = []


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        status = 503 if self.path == "/unavailable.mp4" else 200
        data = b"" if status == 503 else body
        truncated = self.path == "/broken.mp4"
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        sent = 0
        try:
            for offset in range(0, 4096 if truncated else len(data), 4096):
                chunk = data[offset:offset + 4096]
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
                time.sleep(0.001)
        finally:
            requests.append({"path": self.path, "status": status, "sent": sent, "advertised": len(data)})
        self.close_connection = True

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
start = time.monotonic()
report = {"live_app_handle": True, "gui_acceptance": False,
          "provider": os.getenv("PI_PROVIDER"), "model": os.getenv("PI_MODEL"),
          "session_id": os.getenv("PI_SESSION_ID"), "worker_pid": os.getpid(),
          "identity_source": "worker environment (not routing attestation)"}
code = 1
try:
    with tempfile.TemporaryDirectory(prefix="wallbloom-tauri-home-") as directory:
        home = Path(directory)
        (home / ".wallbloom-native-fixture").touch()
        env = dict(os.environ, HOME=directory, CFFIXED_USER_HOME=directory,
                   WALLBLOOM_FIXTURE_URL=f"http://127.0.0.1:{server.server_port}",
                   WALLBLOOM_NATIVE_EVIDENCE=str(evidence))
        with (evidence / "tauri-runtime.log").open("w") as log:
            process = subprocess.run([str(root / "ui/src-tauri/target/debug/wallbloom-native-acceptance")], env=env, cwd=home, stdout=log, stderr=log, timeout=90)
        report["command_exit"] = process.returncode
        if process.returncode != 0:
            raise RuntimeError("live Tauri command test failed; see app-handle.json / tauri-runtime.log")
        app_root = home / "Library/Application Support/Wallbloom"
        downloaded = (app_root / "library/fixture/entry.mp4").read_bytes()
        assert downloaded == body, "downloaded bytes differ"
        assert sorted(p.name for p in app_root.iterdir()) == ["active.json", "library"]
        assert len(requests) == 4, requests
        report.update(sha256=hashlib.sha256(downloaded).hexdigest(), bytes=len(downloaded), staging_clean=True)
        code = 0
except Exception as error:
    report["error"] = str(error)
finally:
    server.shutdown()
    server.server_close()
    worker.join(timeout=5)
    report.update(requests=requests, elapsed_ms=(time.monotonic() - start) * 1000, exit_code=code)
    (evidence / "live-download.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
sys.exit(code)
