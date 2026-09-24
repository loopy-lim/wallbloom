#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Wallbloom"
LIBRARY="$SUPPORT/library"
EVIDENCE="${WALLBLOOM_IMPORT_EVIDENCE:-$HOME/Library/Application Support/Wallbloom/import-evidence}"
mkdir -p "$LIBRARY" "$EVIDENCE"

# Never inspect video imagery. Only import the repository's one approved sample,
# and only when a home-directory copy is byte-identical to it.
SAMPLE="$ROOT/sample-hevc.mp4"
[[ -f "$SAMPLE" ]] || { echo "missing approved local fixture: $SAMPLE" >&2; exit 1; }
SAMPLE_HASH="$(shasum -a 256 "$SAMPLE" | awk '{print $1}')"
CANDIDATES=()
for dir in "$HOME/Movies" "$HOME/Desktop" "$HOME/Downloads" "$HOME/Pictures"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' path; do CANDIDATES+=("$path"); done < <(find "$dir" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' \) -print0 2>/dev/null)
done
MATCH=""
for path in "${CANDIDATES[@]}"; do
  hash="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$hash" == "$SAMPLE_HASH" ]]; then MATCH="$path"; break; fi
done
if [[ -z "$MATCH" ]]; then
  echo "No candidate was byte-identical to the approved local sample; refusing to import unreviewed personal video." >&2
  printf '{"status":"blocked-unreviewed-user-video","candidate_count":%d,"imported":[],"network_downloads":0}\n' "${#CANDIDATES[@]}" > "$EVIDENCE/import-verification.json"
  exit 3
fi

ID="user-video-sample"
PACKAGE="$LIBRARY/$ID"
if [[ -e "$PACKAGE" ]]; then
  [[ -f "$PACKAGE/video.mp4" && "$(shasum -a 256 "$PACKAGE/video.mp4" | awk '{print $1}')" == "$SAMPLE_HASH" ]] || { echo "refusing to overwrite non-matching existing package: $PACKAGE" >&2; exit 1; }
else
  mkdir "$PACKAGE"
  cp "$MATCH" "$PACKAGE/video.mp4"
  cat > "$PACKAGE/wall.json" <<'JSON'
{
  "spec": 0.2,
  "id": "user-video-sample",
  "title": "User Video Sample",
  "type": "video",
  "entry": "video.mp4",
  "preview": "preview.png",
  "loop": true,
  "volume": 0.0,
  "gravity": "cover",
  "author": "User"
}
JSON
fi
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,codec_tag_string -of csv=p=0 "$PACKAGE/video.mp4" | grep -qx 'hevc,hvc1' || { rm -rf "$PACKAGE"; echo 'fixture is not HEVC hvc1' >&2; exit 1; }

ACTIVE="$SUPPORT/active.json"
if [[ -f "$EVIDENCE/active-before-state.json" ]]; then
  BEFORE_PRESENT="$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))["present"]).lower())' "$EVIDENCE/active-before-state.json")"
  BEFORE_HASH="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("sha256") or "null")' "$EVIDENCE/active-before-state.json")"
elif [[ -e "$ACTIVE" ]]; then
  cp -p "$ACTIVE" "$EVIDENCE/active-before.json"
  BEFORE_PRESENT=true
  BEFORE_HASH="$(shasum -a 256 "$ACTIVE" | awk '{print $1}')"
else
  BEFORE_PRESENT=false
  BEFORE_HASH=null
fi
# Select using the same active.json contract as the library UI. Atomic replace.
python3 - "$ACTIVE" "$PACKAGE" <<'PY'
import json, os, pathlib, sys, tempfile
active, package = pathlib.Path(sys.argv[1]), sys.argv[2]
fd, temporary = tempfile.mkstemp(prefix=".active-", dir=active.parent)
try:
    with os.fdopen(fd, "w") as out:
        json.dump({"spec": 0.2, "active": package, "paused": False}, out)
        out.write("\n"); out.flush(); os.fsync(out.fileno())
    os.replace(temporary, active)
finally:
    if os.path.exists(temporary): os.unlink(temporary)
PY

# Capture the installed user's engine window twice and require changing pixels.
PID="$(pgrep -f '^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom' | head -1 || true)"
[[ -n "$PID" ]] || { echo 'installed engine process not running; active.json selected but display cannot be verified' >&2; exit 4; }
HELPER="$EVIDENCE/engine-window.swift"
cat > "$HELPER" <<'SWIFT'
import AppKit
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for window in windows where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    if let id = window[kCGWindowNumber as String] { print(id); break }
}
SWIFT
for i in 1 2; do
  for attempt in {1..20}; do
    WINDOW="$(swift "$HELPER" "$PID" 2>/dev/null | head -1 || true)"
    [[ -n "$WINDOW" ]] && break
    sleep 1
  done
  [[ -n "${WINDOW:-}" ]] || { echo "no visible installed-engine window for PID $PID" >&2; exit 4; }
  screencapture -x -o -l"$WINDOW" "$EVIDENCE/installed-engine-$i.png"
  sleep 1
done
python3 - "$EVIDENCE/installed-engine-1.png" "$EVIDENCE/installed-engine-2.png" "$EVIDENCE/pixel-delta.json" <<'PY'
import json, subprocess, sys
from pathlib import Path
def pixels(p):
    return subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-vf", "scale=24:24", "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
a,b=map(pixels,sys.argv[1:3])
if len(a)!=len(b) or not a: raise SystemExit("screenshot pixel decode failed")
delta=sum(abs(x-y) for x,y in zip(a,b))/len(a)
Path(sys.argv[3]).write_text(json.dumps({"mean_absolute_rgb_delta":delta,"changed":delta>0.5},indent=2)+"\n")
if delta<=0.5: raise SystemExit("captured frames did not show sufficient pixel change")
PY
AFTER_HASH="$(shasum -a 256 "$ACTIVE" | awk '{print $1}')"
python3 - "$ROOT/ui/scripts/import-verification.json" "$MATCH" "$SAMPLE_HASH" "$PACKAGE" "$BEFORE_PRESENT" "$BEFORE_HASH" "$AFTER_HASH" "$PID" "$EVIDENCE" <<'PY'
import json,sys
out,source,digest,package,present,before,after,pid,evidence=sys.argv[1:]
r={"status":"applied-and-captured","source_candidate":source,"source_matches_approved_local_fixture":True,"source_sha256":digest,"network_downloads":0,"imported_packages":[{"id":"user-video-sample","path":package,"type":"video","codec":"hevc","tag":"hvc1"}],"selected":"user-video-sample","active_before":{"present":present=="true","sha256":None if before=="null" else before,"backup":evidence+"/active-before.json" if present=="true" else None},"active_after_sha256":after,"installed_engine_pid":pid,"capture_paths":[evidence+"/installed-engine-1.png",evidence+"/installed-engine-2.png"],"pixel_delta_path":evidence+"/pixel-delta.json","restore":{"if_previously_absent":"rm -f \\\"$HOME/Library/Application Support/Wallbloom/active.json\\\"","if_previously_present":"cp -p "+evidence+"/active-before.json \\\"$HOME/Library/Application Support/Wallbloom/active.json\\\""}}
open(out,"w").write(json.dumps(r,indent=2)+"\n")
PY
cat "$ROOT/ui/scripts/import-verification.json"
