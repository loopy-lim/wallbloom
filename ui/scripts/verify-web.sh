#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-web-evidence-XXXXXX")"
printf 'Evidence directory: %s\n' "$evidence"
pid=''
server_pid=''
audit() {
  python3 - "$evidence" "$1" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
root, mode = pathlib.Path(sys.argv[1]), sys.argv[2]
active = pathlib.Path.home()/'Library/Application Support/Wallbloom/active.json'
installed = pathlib.Path('/Applications/Wallbloom.app')
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
state = {'active': digest(active), 'installed': {str(p.relative_to(installed)):digest(p) for p in sorted(installed.rglob('*')) if p.is_file()},
         'pids': subprocess.run(['pgrep','-f',r'^/Applications/Wallbloom\.app/Contents/MacOS/Wallbloom'], capture_output=True, text=True).stdout.split()}
p = root/'preservation-before.json'
if mode == 'before':
    p.write_text(json.dumps(state, indent=2))
else:
    (root/'preservation-after.json').write_text(json.dumps(state, indent=2))
    if not p.exists() or json.loads(p.read_text()) != state:
        print('FAIL: user active.json / installed bundle / installed process changed; not overwriting possible concurrent user changes')
        sys.exit(1)
    print('PASS: user active.json, installed bundle hashes and installed PIDs unchanged')
PY
}
finish() {
  code=$?
  trap - EXIT
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  if [[ -f "$evidence/preservation-before.json" ]]; then audit after > "$evidence/preservation.log" 2>&1 || code=1; fi
  if [[ -f "$evidence/runtime.log" ]]; then
    runtime_failures="$(sed -n 's/^runtime_failures=//p' "$evidence/runtime.log" | tail -n 1)"
    if [[ "$runtime_failures" =~ ^[0-9]+$ ]] && [[ "$runtime_failures" -eq 0 ]] && ! grep -q '^FAIL:' "$evidence/runtime.log" && [[ "$code" -eq 2 ]]; then
      code=0
    elif [[ ! "$runtime_failures" =~ ^[0-9]+$ ]] || [[ "$runtime_failures" -ne 0 ]] || grep -q '^FAIL:' "$evidence/runtime.log"; then
      code=1
    fi
  fi
  if [[ "$code" -ne 0 ]]; then
    echo 'FAIL: web acceptance assertions or harness checks failed.'
  else
    echo 'PASS: web acceptance assertions completed.'
  fi
  printf 'command_exit=%s\nevidence=%s\n' "$code" "$evidence" | tee "$evidence/result.log"
  exit "$code"
}
trap finish EXIT
printf 'platform=%s model=%s provider=%s\n' "$(uname -s)" "${PI_MODEL:-unset}" "${PI_PROVIDER:-unset}" > "$evidence/environment.log"
[[ "$(uname -s)" == Darwin ]] || { echo 'ATTENTION: requires macOS WKWebView'; exit 2; }
audit before
# Preserve the public API contract alongside the runtime counterexample.
sdk="$(xcrun --show-sdk-path)"
python3 - "$sdk" "$evidence" <<'PY'
import pathlib, sys
sdk, evidence = map(pathlib.Path, sys.argv[1:])
header = sdk/'System/Library/Frameworks/WebKit.framework/Headers/WKWebView.h'
lines = header.read_text().splitlines()
excerpt = [f'{i+1}: {line}' for i, line in enumerate(lines)
           if 'suspend' in line.lower() or 'resume' in line.lower()]
(evidence/'webkit-api.log').write_text(str(header) + '\n' + '\n'.join(excerpt) + '\n')
PY
home="$evidence/home"
package="$home/Library/Application Support/Wallbloom/library/reactive-shader"
mkdir -p "$(dirname "$package")"
cp -R "$root/ui/scripts/web-fixtures/reactive-shader" "$package"
# Compile exactly the production controller with a same-file test extension, not a mock renderer.
# Remove the fixture-authored CSP: the engine must protect even untrusted HTML with no policy.
python3 - "$root" "$evidence" "$package" <<'PY'
import json, pathlib, re, sys
root, evidence, package = map(pathlib.Path, sys.argv[1:])
source = (root/'engine/main.swift').read_text().split('// MARK: - 부트스트랩')[0]
source += '\nenum ActiveJSONError: Error { case invalid }\n'
source += (root/'ui/scripts/web-fixtures/acceptance.swift').read_text()
(evidence/'main.swift').write_text(source)
p = package/'index.html'
p.write_text(re.sub(r'<meta http-equiv="Content-Security-Policy"[^>]*>', '', p.read_text()))
(package.parent.parent/'active.json').write_text(json.dumps({'spec':0.2,'active':str(package),'paused':False}))
PY
python3 "$root/ui/scripts/web-fixtures/security-server.py" "$evidence" > "$evidence/network.log" 2>&1 & server_pid=$!
python3 - "$evidence" <<'PY'
import pathlib, sys, time, urllib.request
p = pathlib.Path(sys.argv[1])
for _ in range(100):
    if (p/'canary-port').exists(): break
    time.sleep(.05)
port = (p/'canary-port').read_text()
assert urllib.request.urlopen(f'http://127.0.0.1:{port}/positive-control').status == 200
assert 'positive-control' in (p/'network-requests.log').read_text()
(p/'network-requests.log').write_text('')
PY
mkdir -p "$home/Library/Application Support/Wallbloom/library/red-video"
if command -v ffmpeg >/dev/null; then
  ffmpeg -v error -f lavfi -i 'color=c=red:s=320x180:r=24:d=2' -c:v libx264 -pix_fmt yuv420p "$home/Library/Application Support/Wallbloom/library/red-video/entry.mp4" > "$evidence/video-fixture.log" 2>&1
  printf '{"spec":0.2,"id":"red-video","title":"Red video","type":"video","entry":"entry.mp4"}\n' > "$home/Library/Application Support/Wallbloom/library/red-video/wall.json"
else
  echo 'ATTENTION: ffmpeg missing; video regression cannot run' >> "$evidence/video-fixture.log"
fi
swiftc -framework AppKit -framework AVFoundation -framework WebKit "$evidence/main.swift" -o "$evidence/web-probe" > "$evidence/build.log" 2>&1
# HOME is consumed by Foundation; no installed app or user active.json is modified.
HOME="$home" CFFIXED_USER_HOME="$home" "$evidence/web-probe" "$package" "$evidence" > "$evidence/runtime.log" 2>&1 & pid=$!
set +e
wait "$pid"; code=$?
set -e
pid=''
python3 - "$evidence/runtime.log" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).read_text())
PY
exit "$code"
