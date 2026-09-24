#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-spaces-evidence-XXXXXX")"
model="${PI_MODEL:-unset}"; provider="${PI_PROVIDER:-unset}"
status=PASS; spaces_status=FAIL; low_power_status=PASS
printf 'Evidence: %s\nModel: %s (provider=%s)\n' "$evidence" "$model" "$provider"

if [[ "$(uname -s)" != Darwin ]]; then
  status=FAIL; spaces_status=FAIL
  echo 'FAIL: macOS required' | tee "$evidence/output.log"
else
  # The ordinary-level probe is Space-local; engine windows intentionally are not.
  cat > "$evidence/traverse.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import AppKit

func key(_ code: CGKeyCode) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw NSError(domain:"Space",code:1) }
    down.flags = .maskControl; up.flags = .maskControl
    down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
    Thread.sleep(forTimeInterval:1.0)
}
func windows(_ pid:Int) -> [(UInt32,CGRect)] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []
    return list.compactMap { item in
        guard (item[kCGWindowOwnerPID as String] as? Int32) == Int32(pid),
              let id=item[kCGWindowNumber as String] as? UInt32,
              let b=item[kCGWindowBounds as String] as? [String:CGFloat],
              let w=b["Width"],let h=b["Height"],w > 100,h > 100 else { return nil }
        return (id,CGRect(x:b["X"] ?? 0,y:b["Y"] ?? 0,width:w,height:h))
    }
}
func capture(_ list:[(UInt32,CGRect)], _ label:String, _ dir:String) -> (Int,[String]) {
    var valid=0; var paths:[String]=[]
    for (id,_) in list {
        let path="\(dir)/\(label)-window\(id).png"
        let task=Process(); task.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture"); task.arguments=["-x","-l",String(id),path]
        do { try task.run(); task.waitUntilExit() } catch { continue }
        guard task.terminationStatus == 0, let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil), let image=CGImageSourceCreateImageAtIndex(source,0,nil), let data=image.dataProvider?.data, let ptr=CFDataGetBytePtr(data) else { continue }
        let count=CFDataGetLength(data); var sum=0; var samples=0
        for i in stride(from:0,to:count,by:max(4,count/4096)) { sum += Int(ptr[i]); samples += 1 }
        // A nonzero sampled channel sum proves captured image pixels, rather than
        // merely the existence of a screenshot file.
        guard samples > 0, sum/samples > 2 else { continue }
        valid += 1; paths.append(path)
        print("CAPTURE \(label) window=\(id) path=\(path) pixels=\(image.width)x\(image.height) sampled_channel_mean=\(sum/samples)")
    }
    return (valid,paths)
}
do {
    let pid=Int(CommandLine.arguments[2])!, mode=CommandLine.arguments[3], dir=CommandLine.arguments[1]
    let app=NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let probe=NSWindow(contentRect:NSRect(x:80,y:80,width:180,height:140),styleMask:[],backing:.buffered,defer:false)
    probe.level = .normal
    probe.backgroundColor = NSColor(calibratedRed:0.13,green:0.83,blue:0.37,alpha:1)
    probe.isOpaque = true
    probe.collectionBehavior = []
    probe.title = "Wallbloom Space Probe"
    probe.orderFrontRegardless()
    app.activate(ignoringOtherApps:true)
    let probeID=UInt32(probe.windowNumber)
    func probeVisible() -> Bool {
        let list=CGWindowListCopyWindowInfo([.optionOnScreenOnly],kCGNullWindowID) as? [[String:Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? UInt32) == probeID }
    }
    func waitProbe(_ expected:Bool, seconds:Double=2) -> Bool {
        let until=Date().addingTimeInterval(seconds)
        while Date() < until {
            if probeVisible() == expected { return true }
            RunLoop.current.run(until:Date().addingTimeInterval(0.1))
        }
        return probeVisible() == expected
    }
    let initial=windows(pid)
    guard !initial.isEmpty else { throw NSError(domain:"Space",code:2,userInfo:[NSLocalizedDescriptionKey:"No visible engine window at start of \(mode)"]) }
    guard waitProbe(true,seconds:3) else { throw NSError(domain:"Space",code:8,userInfo:[NSLocalizedDescriptionKey:"Probe window \(probeID) not in CGWindowList after NSApp launch"]) }
    var spaces:[[String:Any]]=[]
    let (firstCount,firstPaths)=capture(initial,"\(mode)-space-1",dir)
    guard firstCount > 0 else { throw NSError(domain:"Space",code:3,userInfo:[NSLocalizedDescriptionKey:"Initial capture has no visible pixels"]) }
    spaces.append(["space":1,"engine_visible":true,"capture_paths":firstPaths])
    var moved=0; var count=1; var leftOrigin=false; var returned=false
    defer {
        if leftOrigin && !returned { for _ in 0..<moved { try? key(123) }; _ = waitProbe(true,seconds:5) }
        probe.orderOut(nil); app.stop(nil)
    }
    while moved < 32 {
        try key(124); moved += 1
        let isVisible=probeVisible()
        if !isVisible {
            leftOrigin=true
            Thread.sleep(forTimeInterval:0.5)
            let current=windows(pid); count += 1
            let (n,paths)=capture(current,"\(mode)-space-\(count)",dir)
            spaces.append(["space":count,"engine_visible":n > 0,"capture_paths":paths])
            print("SPACE_RESULT mode=\(mode) index=\(count) engine_windows=\(n) visible=\(n > 0)")
        } else if leftOrigin { returned=true; break }
    }
    if !leftOrigin {
        print("MODE_RESULT mode=\(mode) status=ENVIRONMENT space_count=1 transition=inactive_or_single_space probe_return=not_applicable origin_restore=verified")
    } else {
        guard returned else { throw NSError(domain:"Space",code:6,userInfo:[NSLocalizedDescriptionKey:"Probe did not return within 32 Control-Right presses"]) }
        for _ in 0..<moved { try key(123) }
        guard waitProbe(true,seconds:5) else { throw NSError(domain:"Space",code:7,userInfo:[NSLocalizedDescriptionKey:"Could not restore starting Space"]) }
        returned=true
        print("MODE_RESULT mode=\(mode) status=PASS space_count=\(count) source=probe-onscreen cycle origin_restore=verified (\(moved) Control-Left)")
    }
    print("SPACE_JSON \(String(data:try JSONSerialization.data(withJSONObject:spaces),encoding:.utf8)!)")
} catch { fputs("SPACE_ERROR: \(error.localizedDescription)\n",stderr); exit(1) }
SWIFT

  cat > "$evidence/launch.py" <<'PY'
import hashlib, json, os, pathlib, platform, signal, subprocess, sys, tempfile, time
root=pathlib.Path(sys.argv[1]).resolve(); out=pathlib.Path(sys.argv[2]); report={"model":os.getenv("PI_MODEL","unset"),"provider":os.getenv("PI_PROVIDER","unset"),"worker_pid":os.getpid(),"identity_source":"worker environment (not routing attestation)","modes":[],"space_count_source":"ordinary-level probe onscreen disappearance and return"}
proc=None

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
def atom(path,obj):
    tmp=path.with_suffix(".json.tmp")
    with tmp.open("w") as f: json.dump(obj,f); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,path)
try:
    if platform.system()!="Darwin": raise RuntimeError("macOS required")
    user_active=pathlib.Path.home()/"Library/Application Support/Wallbloom/active.json"
    user_before=sha(user_active)
    installed=subprocess.run(["pgrep","-fl","^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom"],capture_output=True,text=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="wallbloom-spaces-home-") as d:
        home=pathlib.Path(d); env=dict(os.environ,HOME=str(home),CFFIXED_USER_HOME=str(home))
        probe=home/"probe.swift"; probe.write_text('import Foundation\nimport AppKit\nimport ApplicationServices\nprint(FileManager.default.homeDirectoryForCurrentUser.path)\nprint("screens=\\(NSScreen.screens.count)")\nprint("accessibility=\\(AXIsProcessTrusted())")\nprint("screen_capture=\\(CGPreflightScreenCaptureAccess())")\n')
        subprocess.run(["swiftc",str(probe),"-o",str(home/"probe")],check=True,timeout=120,stdout=(out/"build.log").open("w"),stderr=subprocess.STDOUT)
        check=subprocess.run([str(home/"probe")],env=env,capture_output=True,text=True,check=True,timeout=20); (out/"preflight.log").write_text(check.stdout)
        lines=check.stdout.splitlines(); report["preflight"]=lines
        if not lines or pathlib.Path(lines[0]).resolve()!=home.resolve(): raise RuntimeError("Foundation HOME isolation failed; engine not launched")
        if "screens=0" in check.stdout: raise RuntimeError("No NSScreen; engine not launched")
        if "accessibility=true" not in check.stdout: raise RuntimeError("Accessibility permission unavailable; keyboard Space traversal cannot be claimed")
        if "screen_capture=true" not in check.stdout: raise RuntimeError("Screen Recording permission unavailable; pixel visibility cannot be claimed")
        subprocess.run(["swiftc","-O","-framework","AppKit","-framework","AVFoundation",str(root/"engine/main.swift"),"-o",str(home/"engine")],check=True,timeout=180,stdout=subprocess.DEVNULL,stderr=(out/"build.log").open("a"))
        app=home/"Library/Application Support/Wallbloom"; library=app/"library"; library.mkdir(parents=True)
        fixtures=[]
        video=library/"spaces-video"; video.mkdir()
        source=root/"sample-hevc.mp4"
        if not source.is_file(): raise RuntimeError("sample-hevc.mp4 missing; video fixture unavailable")
        import shutil
        shutil.copyfile(source,video/"entry.mp4")
        (video/"wall.json").write_text(json.dumps({"spec":0.2,"id":"spaces-video","title":"Spaces video fixture","type":"video","entry":"entry.mp4"}))
        fixtures.append(("video",video))
        web=library/"spaces-web"; web.mkdir()
        (web/"entry.html").write_text('<!doctype html><html><body style="margin:0;background:#e22;color:white;font:48px sans-serif">Wallbloom isolated web Space fixture</body></html>')
        (web/"wall.json").write_text(json.dumps({"spec":0.2,"id":"spaces-web","title":"Spaces web fixture","type":"web","entry":"entry.html"}))
        fixtures.append(("web",web))
        proc=subprocess.Popen([str(home/"engine")],cwd=home,env=env,stdout=(out/"engine.log").open("w"),stderr=subprocess.STDOUT)
        report["isolated_engine_pid"]=proc.pid; modes=[]
        for mode,package in fixtures:
            atom(app/"active.json",{"spec":0.2,"active":str(package),"paused":False})
            time.sleep(3)
            log=out/f"{mode}-spaces.log"
            with log.open("w") as f:
                run=subprocess.run(["swift",str(out/"traverse.swift"),str(out),str(proc.pid),mode],env=env,stdout=f,stderr=subprocess.STDOUT,timeout=240)
            text=log.read_text(errors="replace"); captures=[]
            for line in text.splitlines():
                if line.startswith("CAPTURE "):
                    try: captures.append({k:v for k,v in (part.split("=",1) for part in line.split()[1:])})
                    except ValueError: pass
            import re
            result=re.search(r"MODE_RESULT mode=(\w+) status=(\w+) space_count=(\d+).*?origin_restore=(.*)",text)
            environment=re.search(r"MODE_RESULT mode=(\w+) status=ENVIRONMENT space_count=(\d+) transition=([^ ]+).*?origin_restore=(.*)",text)
            count=int(result.group(3)) if result else (int(environment.group(2)) if environment else None)
            data=re.search(r"SPACE_JSON (\[.*\])",text)
            space_results=json.loads(data.group(1)) if data else []
            passed=run.returncode==0 and (result is not None or environment is not None) and all(int(item.get("sampled_channel_mean","0"))>2 for item in captures)
            modes.append({"mode":mode,"status":"PASS" if passed else "FAIL","environment_result":bool(environment),"transition_result":environment.group(3) if environment else None,"space_count":count,"space_count_source":report["space_count_source"] if count is not None else None,"space_results":space_results,"captures":captures,"log":str(log),"origin_restore":(result.group(4) if result else environment.group(4) if environment else "NOT VERIFIED"),"log_text":text if run.returncode!=0 or not passed else None})
        report["modes"]=modes
        report["spaces_status"]="PASS" if len(modes)==2 and all(m["status"]=="PASS" for m in modes) else "FAIL"
        if report["spaces_status"]!="PASS": report["blocker"]="One or more mode traversal/capture checks failed; inspect per-mode logs and captures"
except Exception as e:
    report["spaces_status"]="FAIL"; report["blocker"]=str(e)
finally:
    if proc is not None:
        proc.terminate()
        try: proc.wait(timeout=8)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait(timeout=5)
        report["isolated_engine_stopped"]=proc.poll() is not None
    if 'user_active' in locals():
        report["user_active_sha256_before"]=user_before; report["user_active_sha256_after"]=sha(user_active)
        after=subprocess.run(["pgrep","-fl","^/Applications/Wallbloom.app/Contents/MacOS/Wallbloom"],capture_output=True,text=True).stdout.strip()
        report["installed_processes_before"]=installed; report["installed_processes_after"]=after
        report["user_state_unchanged"]=user_before==sha(user_active) and installed==after
        if not report["user_state_unchanged"]: report["spaces_status"]="FAIL"; report["blocker"]="User active.json or installed process state changed"
report["exit_code"]=0 if report.get("spaces_status")=="PASS" else 2
(out/"spaces-result.json").write_text(json.dumps(report,indent=2)+"\n")
print(json.dumps(report,indent=2))
sys.exit(report["exit_code"])
PY

  set +e
  python3 "$evidence/launch.py" "$root" "$evidence" >"$evidence/launch-output.log" 2>&1
  launch_status=$?
  set -e
  cat "$evidence/launch-output.log" | tee "$evidence/output.log"
  if [[ $launch_status -eq 0 ]]; then spaces_status=PASS; else spaces_status=FAIL; status=FAIL; fi

  power_before="$(pmset -g | grep -i lowpowermode | tee -a "$evidence/output.log" | grep -Eo '[01]$' | tail -1)"
  printf 'lowpowermode_before=%s\n' "${power_before:-unknown}" | tee -a "$evidence/output.log"
  if ! sudo -n true >"$evidence/sudo-preflight.log" 2>&1; then
    low_power_status=HITL
    [[ "$status" == FAIL ]] || status=HITL
    echo 'HITL: sudo -n unavailable; low-power mode NOT measured. Record `pmset -g`, run `sudo pmset -a lowpowermode 1`, verify, then restore the recorded prior value. HITL is not PASS.' | tee -a "$evidence/output.log"
  elif [[ "$power_before" != 0 && "$power_before" != 1 ]]; then
    low_power_status=FAIL; status=FAIL
    echo 'FAIL: could not determine prior low-power setting; refusing to change it.' | tee -a "$evidence/output.log"
  elif sudo -n pmset -a lowpowermode 1 >"$evidence/pmset-enable.log" 2>&1; then
    sleep 2
    pmset -g | grep -i lowpowermode | tee -a "$evidence/output.log" || true
    if sudo -n pmset -a lowpowermode "$power_before" >"$evidence/pmset-restore.log" 2>&1; then low_power_status=PASS
    else low_power_status=FAIL; status=FAIL; echo 'FAIL: low-power mode changed but could not be restored; run sudo pmset -a lowpowermode 0 manually.' | tee -a "$evidence/output.log"; fi
  else
    low_power_status=HITL
    [[ "$status" == FAIL ]] || status=HITL
    echo 'HITL: sudo -n pmset unavailable; low-power mode NOT measured. For manual verification, record `pmset -g` first, run `sudo pmset -a lowpowermode 1`, verify with `pmset -g`, then restore the recorded prior value with `sudo pmset -a lowpowermode <prior-value>`.' | tee -a "$evidence/output.log"
  fi
fi

python3 - "$evidence" "$status" "$spaces_status" "$low_power_status" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); prior=json.loads((p/'spaces-result.json').read_text()) if (p/'spaces-result.json').exists() else {}
result={'status':sys.argv[2],'spaces_status':sys.argv[3],'low_power_status':sys.argv[4],'evidence':str(p),'model':prior.get('model','unset'),'provider':prior.get('provider','unset'),'modes':prior.get('modes',[]),'space_count_by_mode':{m['mode']:m.get('space_count') for m in prior.get('modes',[])},'space_count_source':prior.get('space_count_source'),'user_state_unchanged':prior.get('user_state_unchanged'),'isolated_engine_stopped':prior.get('isolated_engine_stopped'),'blocker':prior.get('blocker')}
if sys.argv[4]=='HITL': result['low_power_user_instructions']='Record `pmset -g`; run `sudo pmset -a lowpowermode 1`; verify; restore the recorded prior value. HITL is not PASS.'
(p/'result.json').write_text(json.dumps(result,indent=2)+'\n')
PY
printf 'RESULT=%s spaces=%s low_power=%s evidence=%s\n' "$status" "$spaces_status" "$low_power_status" "$evidence"
[[ "$status" != FAIL ]]
