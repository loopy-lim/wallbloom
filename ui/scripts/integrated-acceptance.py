#!/usr/bin/env python3
"""Strict same-HOME product input -> engine-window pixels gate; no SKIP success."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1]).resolve()
EVIDENCE = Path(tempfile.mkdtemp(prefix='wallbloom-integrated-evidence-'))
REPORT = {'status': 'FAIL', 'skip': [], 'transitions': [], 'evidence': str(EVIDENCE),
          'started_at': datetime.datetime.now().astimezone().isoformat(),
          'model': os.getenv('PI_MODEL'), 'provider': os.getenv('PI_PROVIDER'),
          'identity_note': 'Environment only; not Codex routing attestation',
          'timing': 'Python monotonic before OS event submission through captured pixel analysis; conservative upper bound, not ACK'}


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, timeout=kwargs.pop('timeout', 120), **kwargs)


def output(args, **kwargs):
    return run(args, capture_output=True, text=True, **kwargs).stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def app_digest(path):
    return {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob('*')) if p.is_file()}


def user_state():
    processes = subprocess.run(['pgrep', '-fl', '^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom'], capture_output=True, text=True)
    return {'active': digest(ACTIVE), 'installed_app': app_digest(INSTALLED), 'processes': processes.stdout.strip()}


def wait_file(path, processes, seconds=40):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if any(p.poll() is not None for p in processes):
            raise RuntimeError('isolated UI/engine exited; inspect process logs')
        if path.exists():
            try:
                return json.loads(path.read_text())
            except json.JSONDecodeError:
                pass
        error = EVIDENCE / 'gui-integrated-error.json'
        if error.exists():
            raise RuntimeError(error.read_text())
        time.sleep(.025)
    raise RuntimeError(f'timeout awaiting {path.name}')


def interrupt(signum, _frame):
    raise RuntimeError(f'interrupted: {signum}')


ACTIVE = Path.home() / 'Library/Application Support/Wallbloom/active.json'
INSTALLED = Path('/Applications/Wallbloom.app')
children = []
logs = []
desktop = None
probe = None
before = user_state()
REPORT['user_before'] = before
backup = EVIDENCE / 'user-backup'
backup.mkdir()
if ACTIVE.exists():
    shutil.copy2(ACTIVE, backup / 'active.json')
if INSTALLED.exists():
    shutil.copytree(INSTALLED, backup / 'Wallbloom.app', symlinks=True)
code = 2
signal.signal(signal.SIGINT, interrupt)
signal.signal(signal.SIGTERM, interrupt)
print(f'Evidence: {EVIDENCE}', flush=True)
try:
    if platform.system() != 'Darwin':
        raise RuntimeError('macOS WindowServer required')
    REPORT['environment'] = {'os': output(['sw_vers']), 'hardware': output(['sysctl', '-n', 'hw.model']),
                             'memory_bytes': output(['sysctl', '-n', 'hw.memsize'])}
    with tempfile.TemporaryDirectory(prefix='wallbloom-integrated-home-') as directory:
        home = Path(directory)
        env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                   WALLBLOOM_GUI_EVIDENCE=str(EVIDENCE), WALLBLOOM_INTEGRATED='1')
        probe = EVIDENCE / 'probe'
        with (EVIDENCE / 'build.log').open('w') as log:
            run(['swiftc', ROOT / 'ui/scripts/integrated-probe.swift', '-o', probe], stdout=log, stderr=log)
            preflight = json.loads(output([probe, 'preflight'], env=env))
            REPORT['preflight'] = preflight
            if Path(preflight['home']).resolve() != home.resolve() or not preflight['screens']:
                raise RuntimeError('Foundation HOME isolation or display preflight failed; not launching apps')
            # A new destination forces clean compilation without modifying any app bundle.
            run(['swiftc', '-O', '-framework', 'AppKit', '-framework', 'AVFoundation',
                 ROOT / 'engine/main.swift', '-o', home / 'engine'], stdout=log, stderr=log, timeout=180)
            REPORT['swift_clean_build'] = {'status': 'PASS', 'at': datetime.datetime.now().astimezone().isoformat(),
                                           'source_sha256': digest(ROOT / 'engine/main.swift')}
            run(['bun', 'run', 'build'], cwd=ROOT / 'ui', stdout=log, stderr=log)
            run(['cargo', 'build', '--features', 'native-acceptance', '--bin', 'wallbloom-ui'],
                cwd=ROOT / 'ui/src-tauri', env=dict(os.environ, TAURI_CONFIG='{"build":{"devUrl":null}}'),
                stdout=log, stderr=log, timeout=600)
        desktop = json.loads(output([probe, 'desktop']))
        app = home / 'Library/Application Support/Wallbloom'
        for name, color in [('fixture-a', 'red'), ('fixture-b', 'blue'), ('fixture-video', None)]:
            package = app / 'library' / name
            media = package / 'media/clip.mp4'
            media.parent.mkdir(parents=True)
            if color:
                run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', f'color=c={color}:s=640x360:r=24:d=6',
                     '-c:v', 'libx264', '-pix_fmt', 'yuv420p', media])
            else:
                shutil.copy2(ROOT / 'sample-hevc.mp4', media)
            # Third-party-style variant, NOT a claim of independently authored compatibility.
            manifest = dict(spec=.1, id=name, name=name, type='video', entry='media/clip.mp4', vendor={'unknown': True})
            (package / 'wall.json').write_text(json.dumps(manifest))
        REPORT['fixture'] = 'Synthetic v0.1/name, nested media path, missing preview, unknown vendor field; not external provenance'
        REPORT['video'] = json.loads(output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', ROOT / 'sample-hevc.mp4']))
        for label, binary in [('engine', home / 'engine'), ('ui', ROOT / 'ui/src-tauri/target/debug/wallbloom-ui')]:
            log = (EVIDENCE / f'{label}.log').open('w')
            logs.append(log)
            children.append(subprocess.Popen([str(binary)], cwd=home, env=env, stdout=log, stderr=log))
        engine, ui = children
        REPORT['isolated_pids'] = {'engine': engine.pid, 'ui': ui.pid}

        def windows(pid):
            return json.loads(output([probe, 'windows', pid], timeout=5))

        previous_rgb = None
        for phase, channel in [('initial', 0), ('mouse', 2), ('keyboard', 0), ('performance', None)]:
            ready = wait_file(EVIDENCE / f'gui-integrated-{phase}-ready.json', children)
            run([probe, 'activate', ui.pid])
            time.sleep(.25)
            ui_windows = sorted([w for w in windows(ui.pid) if w.get('kCGWindowLayer') == 0 and w.get('kCGWindowIsOnscreen') and w['kCGWindowBounds']['Width'] > 100],
                                key=lambda w: w['kCGWindowBounds']['Width'] * w['kCGWindowBounds']['Height'], reverse=True)
            if not ui_windows:
                raise RuntimeError('no product UI window')
            bounds = ui_windows[0]['kCGWindowBounds']
            args = ['osascript', '-e', f'''tell application "System Events"
set targetProcess to first application process whose unix id is {ui.pid}
set frontmost of targetProcess to true
delay 0.3
key code 36
end tell''']
            if phase == 'mouse':
                args = [probe, 'mouse', bounds['X'] + ready['x'],
                        bounds['Y'] + bounds['Height'] - ready['innerHeight'] + ready['y']]
            run(['screencapture', '-x', '-l', ui_windows[0]['kCGWindowNumber'], EVIDENCE / f'{phase}-ui.png'])
            REPORT.setdefault('inputs', []).append({'phase': phase, 'bounds': bounds, 'ready': ready, 'command': list(map(str, args))})
            start = time.monotonic()
            run(args, timeout=5)
            trusted = wait_file(EVIDENCE / f'gui-integrated-{phase}-input.json', children, seconds=3)
            measurement = {'phase': phase, 't0_monotonic': start, 'trusted_input': trusted, 'status': 'FAIL'}
            REPORT['transitions'].append(measurement)
            if channel is None:
                deadline = time.monotonic() + 3
                while Path(json.loads((app / 'active.json').read_text())['active']).name != 'fixture-video':
                    if time.monotonic() > deadline:
                        raise RuntimeError('performance video selection not applied')
                    time.sleep(.025)
                time.sleep(10)  # warmup; CPU samples exclude build/capture/UI input
                video_pixels = []
                for index in range(2):
                    video_window = next(w for w in windows(engine.pid) if w['kCGWindowBounds']['Width'] > 100 and w.get('kCGWindowLayer', 0) < 0)
                    image = EVIDENCE / f'performance-video-{index}.png'
                    run(['screencapture', '-x', '-l', video_window['kCGWindowNumber'], image])
                    video_pixels.append(run(['ffmpeg', '-v', 'error', '-i', image, '-vf', 'scale=24:24', '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True).stdout)
                    time.sleep(1)
                motion = statistics.mean(abs(a-b) for a, b in zip(*video_pixels))
                REPORT['performance_video_motion_delta'] = motion
                if motion <= .1:
                    raise RuntimeError('performance video has no captured motion; refusing idle CPU measurement')
                samples = []
                for _ in range(15):
                    cpu, rss = output(['ps', '-p', engine.pid, '-o', '%cpu=', '-o', 'rss=']).split()
                    samples.append({'at': datetime.datetime.now().astimezone().isoformat(), 'cpu_percent': float(cpu), 'rss_kib': int(rss)})
                    time.sleep(1)
                REPORT['performance'] = {'status': 'PASS', 'scope': 'engine process only; excludes WindowServer/decoder/GPU and UI; ps CPU is OS averaged',
                    'warmup_seconds': 10, 'samples': samples, 'cpu_mean_percent': statistics.mean(s['cpu_percent'] for s in samples),
                    'rss_mean_mib': statistics.mean(s['rss_kib'] for s in samples) / 1024,
                    'rss_peak_mib': max(s['rss_kib'] for s in samples) / 1024}
                measurement['status'] = 'PASS'
                continue
            matched = False
            attempts = 0
            while time.monotonic() - start < 3:
                candidates = [w for w in windows(engine.pid) if w['kCGWindowBounds']['Width'] > 100 and w.get('kCGWindowLayer', 0) < 0]
                for window in candidates[:1]:
                    image = EVIDENCE / f'{phase}-{attempts}.png'
                    attempts += 1
                    capture = subprocess.run(['screencapture', '-x', '-l', str(window['kCGWindowNumber']), str(image)], capture_output=True, timeout=5)
                    if capture.returncode:
                        measurement['capture_error'] = capture.stderr.decode(errors='replace')
                        continue
                    rgb = run(['ffmpeg', '-v', 'error', '-i', image, '-vf', 'scale=24:24', '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], capture_output=True, timeout=5).stdout
                    means = [statistics.mean(rgb[c::3]) for c in range(3)]
                    delta = statistics.mean(abs(a - b) for a, b in zip(previous_rgb, rgb)) if previous_rgb else None
                    visible = time.monotonic()
                    measurement.update(window_id=window['kCGWindowNumber'], screenshot=str(image), rgb_mean=means,
                                       pixel_delta=delta, t_visible_monotonic=visible, visible_ms=(visible-start)*1000)
                    if means[channel] > 100 and all(means[channel]-means[c] > 80 for c in range(3) if c != channel) and (delta is None or delta > 8):
                        matched = visible - start <= 3
                        previous_rgb = rgb
                        break
                if matched:
                    break
                time.sleep(.025)
            measurement['status'] = 'PASS' if matched else 'FAIL'
            if not matched:
                raise RuntimeError(f'{phase}: no qualifying visible frame within 3 seconds')
        REPORT['status'] = 'PASS'
        code = 0
except Exception as error:
    REPORT['attention'] = str(error)
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
    for log in logs:
        log.close()
    REPORT['isolated_processes_stopped'] = all(p.poll() is not None for p in children)
    if desktop and probe:
        subprocess.run([str(probe), 'restore', str(desktop['frontmost']), str(desktop['x']), str(desktop['y'])], capture_output=True, timeout=5)
    after = user_state()
    REPORT['user_after'] = after
    REPORT['user_state_unchanged'] = before == after
    if before != after:
        # Never restart/kill a user's process to disguise a state mismatch.
        if before['active'] != after['active']:
            if (backup / 'active.json').exists():
                ACTIVE.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(backup / 'active.json', ACTIVE)
            else:
                ACTIVE.unlink(missing_ok=True)
        if before['installed_app'] != after['installed_app']:
            if INSTALLED.exists():
                shutil.rmtree(INSTALLED)
            if (backup / 'Wallbloom.app').exists():
                shutil.copytree(backup / 'Wallbloom.app', INSTALLED, symlinks=True)
        REPORT['restored_user_state'] = user_state()
        REPORT.update(status='FAIL', attention='User state changed; files restored. Process differences require attention, not automatic restart.')
        code = 2
    REPORT['exit_code'] = code
    (EVIDENCE / 'result.json').write_text(json.dumps(REPORT, indent=2) + '\n')
    print(json.dumps(REPORT, indent=2))
sys.exit(code)
