#!/usr/bin/env python3
"""Real Wry UI acceptance: DOM actions + trusted macOS keyboard, isolated HOME."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

root, evidence = map(lambda x: Path(x).resolve(), sys.argv[1:3])
report = {"status": "FAIL", "provider": os.getenv("PI_PROVIDER"), "model": os.getenv("PI_MODEL"),
          "session_id": os.getenv("PI_SESSION_ID"), "identity_source": "worker environment, not routing attestation; Loop is not DAS",
          "screenshots": [], "actions": []}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def capture(image, pid):
    ids = subprocess.run([str(evidence / 'gui-window'), str(pid)], capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    if not ids: raise RuntimeError('No visible native GUI window found')
    subprocess.run(['screencapture', '-x', '-l', ids, str(image)], check=True, timeout=15)
    if not image.exists(): raise RuntimeError('GUI window capture missing')
    report['window_id'] = ids

def processes():
    return subprocess.run(['pgrep', '-fl', '^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom'], capture_output=True, text=True).stdout

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/download.mp4':
            self.send_error(503)
            return
        data = (root / 'sample-hevc.mp4').read_bytes()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        for offset in range(0, len(data), 65536):
            self.wfile.write(data[offset:offset + 65536])
            self.wfile.flush()
            time.sleep(.02)
    def log_message(self, fmt, *args):
        with (evidence / 'gui-http.log').open('a') as f:
            f.write(fmt % args + '\n')

active = Path.home() / 'Library/Application Support/Wallbloom/active.json'
before = digest(active), processes()
report['user_before'] = before
process = None
server = None
code = 2

def interrupt(signum, frame):
    raise RuntimeError(f'interrupted: {signum}')
signal.signal(signal.SIGTERM, interrupt)
signal.signal(signal.SIGINT, interrupt)
try:
    subprocess.run(['swiftc', str(root / 'ui/scripts/gui-window.swift'), '-o', str(evidence / 'gui-window')], check=True, timeout=120)
    with tempfile.TemporaryDirectory(prefix='wallbloom-gui-home-') as directory:
        home = Path(directory)
        app = home / 'Library/Application Support/Wallbloom'
        package = app / 'library/fixture'
        package.mkdir(parents=True)
        shutil.copyfile(root / 'sample-hevc.mp4', package / 'entry.mp4')
        (package / 'wall.json').write_text(json.dumps(dict(spec=.2, id='fixture', title='fixture', type='video', entry='entry.mp4')))
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), WALLBLOOM_GUI_EVIDENCE=str(evidence),
                   WALLBLOOM_GUI_BASE=f'http://127.0.0.1:{server.server_port}')
        with (evidence / 'gui-process.log').open('w') as output:
            process = subprocess.Popen([str(root / 'ui/src-tauri/target/debug/wallbloom-ui')], env=env, stdout=output, stderr=output)
            keyboard_sent = False
            progress_captured = False
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f'WebView process exited: {process.returncode}')
                if (evidence / 'gui-keyboard-ready.json').exists() and not keyboard_sent:
                    script = f'''tell application "System Events"
set targetProcess to first application process whose unix id is {process.pid}
set frontmost of targetProcess to true
delay 0.3
key code 36
end tell'''
                    result = subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=15)
                    report['actions'].append(dict(action='OS Enter on focused card', exit=result.returncode, stderr=result.stderr))
                    if result.returncode: raise RuntimeError('macOS keyboard automation failed')
                    keyboard_sent = True
                if (evidence / 'gui-progress.json').exists() and not progress_captured:
                    image = evidence / 'gui-progress.png'
                    capture(image, process.pid)
                    report['screenshots'].append(str(image))
                    progress_captured = True
                if (evidence / 'gui-complete.json').exists(): break
                time.sleep(.03)
            else: raise RuntimeError('real WebView harness timed out')
            result = json.loads((evidence / 'gui-complete.json').read_text())
            report.update(result)
            image = evidence / 'gui-final.png'
            capture(image, process.pid)
            report['screenshots'].append(str(image))
            report['selected_state'] = json.loads((app / 'active.json').read_text())
            report['byte_equality'] = digest(app / 'library/download/entry.mp4') == digest(root / 'sample-hevc.mp4')
            report['staging_cleanup'] = not list(app.glob('download-*'))
            report['failed_package_absent'] = not (app / 'library/failure').exists()
            assert result['status'] == 'PASS', result.get('error', 'WebView checks failed')
            assert keyboard_sent and progress_captured, 'missing keyboard or progress evidence'
            assert Path(report['selected_state']['active']).resolve() == package.resolve(), 'selected package mismatch'
            assert report['byte_equality'] and report['staging_cleanup'] and report['failed_package_absent']
            code = 0
except Exception as error:
    report.update(status='FAIL', error=str(error) or repr(error))
finally:
    if process:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        report['gui_process_exit'] = process.returncode
    if server: server.shutdown()
    report['user_after'] = digest(active), processes()
    report['user_state_unchanged'] = before == report['user_after']
    if not report['user_state_unchanged']:
        report.update(status='FAIL', error='user state/process changed')
        code = 2
    report['command_exit'] = code
    (evidence / 'gui-acceptance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
sys.exit(code)
