#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-scene-XXXXXX")"
home="$evidence/home"
mkdir -p "$home"
printf 'Evidence directory: %s\n' "$evidence"
printf 'provider=%s model=%s verifier_pid=%s\n' "${PI_PROVIDER:-unset}" "${PI_MODEL:-unset}" "$$" | tee "$evidence/environment.log"
trap 'if [[ -n "${engine_pid:-}" ]]; then kill "$engine_pid" 2>/dev/null || true; wait "$engine_pid" 2>/dev/null || true; fi; if [[ -n "${scene_pid:-}" ]]; then kill "$scene_pid" 2>/dev/null || true; wait "$scene_pid" 2>/dev/null || true; fi' EXIT
swiftc -O -framework AppKit -framework Metal -framework MetalKit "$root/ui/scripts/scene-fixture/ParticleGarden.swift" -o "$evidence/ParticleGarden"
chmod +x "$evidence/ParticleGarden"
mkdir -p "$home/Library/Application Support/Wallbloom/library/fixture-scene/runtime" "$home/Library/Application Support/Wallbloom/library/fixture-video"
cp "$evidence/ParticleGarden" "$home/Library/Application Support/Wallbloom/library/fixture-scene/runtime/ParticleGarden"
cp "$root/sample-hevc.mp4" "$home/Library/Application Support/Wallbloom/library/fixture-video/entry.mp4"
cat > "$home/Library/Application Support/Wallbloom/library/fixture-scene/wall.json" <<'EOF'
{"spec":0.2,"id":"fixture-scene","title":"Particle Garden","type":"scene","entry":"runtime/ParticleGarden","scene":{"interactive":false}}
EOF
cat > "$home/Library/Application Support/Wallbloom/library/fixture-video/wall.json" <<'EOF'
{"spec":0.2,"id":"fixture-video","title":"Video fixture","type":"video","entry":"entry.mp4"}
EOF
app="$home/Library/Application Support/Wallbloom"
atom(){ python3 - "$app/active.json" "$1" <<'PY'
import json,os,sys,tempfile
p=sys.argv[1]; d={'spec':0.2,'active':sys.argv[2],'paused':False}
fd,t=tempfile.mkstemp(dir=os.path.dirname(p)); os.write(fd,json.dumps(d).encode()); os.fsync(fd); os.close(fd); os.replace(t,p)
PY
}
WALLBLOOM_SUPPORT_DIR="$app" "$root/Wallbloom.app/Contents/MacOS/Wallbloom" >"$evidence/engine.log" 2>&1 & engine_pid=$!
sleep 2
atom "$app/library/fixture-scene"
sleep 3
pgrep -P "$engine_pid" > "$evidence/scene-child.pid"
screencapture -x "$evidence/scene.png"
[[ -s "$evidence/scene.png" ]] || { echo 'FAIL: no desktop capture'; exit 1; }
file "$evidence/scene.png" | tee "$evidence/capture.log"
swift -e 'import AppKit; import Foundation; let i=NSBitmapImageRep(data:try! Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))!; var n=0; for y in stride(from:0,to:i.pixelsHigh,by:24) { for x in stride(from:0,to:i.pixelsWide,by:24) { let c=i.colorAt(x:x,y:y)!.usingColorSpace(NSColorSpace.deviceRGB)!; if c.blueComponent > 0.35 && c.greenComponent > 0.16 && c.blueComponent > c.redComponent * 1.25 { n += 1 } } }; print("sampled_fixture_like_pixels=\(n)"); exit(n > 0 ? 0 : 1)' "$evidence/scene.png" | tee "$evidence/pixel-samples.log"
printf 'PASS: scene child running; capture contains fixture-like pixel samples: %s\n' "$evidence/scene.png" | tee -a "$evidence/result.log"
atom "$app/library/fixture-video"
sleep 3
if pgrep -P "$engine_pid" >/dev/null; then echo 'FAIL: scene child survived video switch' | tee -a "$evidence/result.log"; exit 1; fi
printf 'PASS: scene→video switch terminated scene process; video selection logged\n' | tee -a "$evidence/result.log"
atom "$app/library/fixture-scene"
sleep 2
scene_pid="$(pgrep -P "$engine_pid" | head -1)"
[[ -n "$scene_pid" ]] || { echo 'FAIL: scene did not restart'; exit 1; }
ps -p "$scene_pid" -o %cpu= | tee "$evidence/scene-cpu.txt"
printf 'scene_cpu_percent=%s; recorded instantaneous sample, not sustained benchmark\n' "$(cat "$evidence/scene-cpu.txt" | xargs)" | tee -a "$evidence/result.log"
kill "$engine_pid"
wait "$engine_pid" || true
engine_pid=""
sleep 2
if kill -0 "$scene_pid" 2>/dev/null; then echo 'FAIL: scene child survived engine shutdown' | tee -a "$evidence/result.log"; exit 1; fi
scene_pid=""
printf 'PASS: engine shutdown reclaimed scene child\n' | tee -a "$evidence/result.log"
cat "$evidence/engine.log"
printf 'Evidence retained at %s\n' "$evidence"
