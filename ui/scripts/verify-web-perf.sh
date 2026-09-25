#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
evidence="$(mktemp -d "${TMPDIR:-/tmp}/wallbloom-web-perf-XXXXXX")"
model="${PI_MODEL:-unset}"; provider="${PI_PROVIDER:-unset}"
printf 'Web perf evidence: %s\n' "$evidence"
if [[ "$(uname -s)" != Darwin ]]; then
  printf '{"status":"NOT_MEASURED","reason":"requires macOS WebKit/WKWebView","model":"%s","provider":"%s","evidence":"%s"}\n' "$model" "$provider" "$evidence" | tee "$evidence/result.json"
  exit 1
fi
# Collect full process snapshots once per second, scoped to this isolated acceptance probe
# and its descendants (including WebKit WebContent, GPU and Networking helpers).
cat > "$evidence/sampler.py" <<'PY'
import json, subprocess, sys, time
out=sys.argv[1]+'/process-samples.jsonl'
with open(out,'w', buffering=1) as f:
    while True:
        rows=subprocess.run(['ps','-axo','pid=,ppid=,pcpu=,rss=,command='],capture_output=True,text=True).stdout.splitlines()
        procs={}
        for line in rows:
            p=line.strip().split(None,4)
            if len(p)==5:
                try: procs[int(p[0])]={'ppid':int(p[1]),'cpu':float(p[2]),'rss_kib':int(p[3]),'command':p[4]}
                except ValueError: pass
        roots=[pid for pid,v in procs.items() if 'web-probe' in v['command'] and '/wallbloom-web-evidence-' in v['command']]
        try: phase=open(sys.argv[1]+'/perf-phase').read().strip()
        except OSError: phase='unmarked'
        if roots:
            tracked=set(roots)
            changed=True
            while changed:
                changed=False
                for pid,v in procs.items():
                    if v['ppid'] in tracked and pid not in tracked: tracked.add(pid); changed=True
            members=[]
            for pid in sorted(tracked):
                if pid in procs:
                    v=procs[pid]; members.append(dict(pid=pid,cpu_percent=v['cpu'],rss_kib=v['rss_kib'],command=v['command']))
            f.write(json.dumps({'time':time.time(),'phase':phase,'processes':members})+'\n')
        time.sleep(1)
PY
python3 "$evidence/sampler.py" "$evidence" &
sampler_pid=$!
finish_sampler() { kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true; }
trap finish_sampler EXIT
set +e
WALLBLOOM_PERF_PHASE_FILE="$evidence/perf-phase" bash "$root/ui/scripts/verify-web.sh" >"$evidence/web-acceptance.log" 2>&1
web_exit=$?
set -e
finish_sampler
trap - EXIT
web_evidence="$(grep -E '^Evidence directory:' "$evidence/web-acceptance.log" | tail -1 | awk '{print $3}')"
start="$(date '+%Y-%m-%dT%H:%M:%S%z')"
summary="$evidence/summary.json"
python3 - "$evidence/process-samples.jsonl" "$summary" <<'PY'
import json,sys
snapshots=[]
for line in open(sys.argv[1]):
    try:
        x=json.loads(line)
        if x['processes']: snapshots.append(x)
    except (ValueError,KeyError): pass
if snapshots:
    cpu=[sum(p['cpu_percent'] for p in x['processes']) for x in snapshots]
    rss=[sum(p['rss_kib'] for p in x['processes'])/1024 for x in snapshots]
    phases={}
    for x in snapshots:
        phase=phases.setdefault(x.get('phase','unmarked'),{'samples':0,'cpu_sum':0,'rss_sum':0,'cpu_max_percent':0,'rss_max_mib':0})
        c=sum(p['cpu_percent'] for p in x['processes']); r=sum(p['rss_kib'] for p in x['processes'])/1024
        phase['samples']+=1; phase['cpu_sum']+=c; phase['rss_sum']+=r
        phase['cpu_max_percent']=max(phase['cpu_max_percent'],c); phase['rss_max_mib']=max(phase['rss_max_mib'],r)
    for phase in phases.values():
        phase['cpu_average_percent']=phase.pop('cpu_sum')/phase['samples']; phase['rss_average_mib']=phase.pop('rss_sum')/phase['samples']
    by={}
    for x in snapshots:
        for p in x['processes']:
            name=p['command'].rsplit('/',1)[-1]
            a=by.setdefault(name,{'samples':0,'cpu_percent_sum':0,'rss_mib_sum':0})
            a['samples']+=1; a['cpu_percent_sum']+=p['cpu_percent']; a['rss_mib_sum']+=p['rss_kib']/1024
    result={'samples':len(snapshots),'cpu_average_percent':sum(cpu)/len(cpu),'cpu_max_percent':max(cpu),'rss_average_mib':sum(rss)/len(rss),'rss_max_mib':max(rss),'process_breakdown':by,'phase_measurements':phases}
else: result={'samples':0,'reason':'isolated web-probe process tree was not observed during sampling'}
json.dump(result,open(sys.argv[2],'w'),indent=2)
PY
python3 - "$evidence" "$web_exit" "$web_evidence" "$model" "$provider" "$start" <<'PY'
import datetime,json,pathlib,platform,subprocess,sys
folder,web_exit,web_evidence,model,provider,when=sys.argv[1:]
folder=pathlib.Path(folder); summary=json.loads((folder/'summary.json').read_text())
try:
    hw=subprocess.run(['system_profiler','SPHardwareDataType'],capture_output=True,text=True).stdout
    chip=next((x.strip().split(':',1)[1].strip() for x in hw.splitlines() if 'Chip:' in x),'unknown')
    displays=subprocess.run(['system_profiler','SPDisplaysDataType'],capture_output=True,text=True).stdout
    display='; '.join(x.strip() for x in displays.splitlines() if 'Resolution:' in x) or 'unknown'
except Exception: chip=display='unavailable'
status='MEASURED' if summary.get('samples',0)>0 else 'NOT_MEASURED'
if status=='MEASURED':
    cpu=summary['cpu_average_percent']; verdict='PASS' if cpu<10 else 'FAIL'
    report=f"## WebKit engine process CPU/RSS ({when})\n\nEnvironment: {chip} / macOS {platform.mac_ver()[0]} / {display}. Model `{model}` provider `{provider}`. Acceptance evidence `{web_evidence}`, samples `{folder}`.\n\nCPU average/max {cpu:.3f}% / {summary['cpu_max_percent']:.3f}%; RSS average/max {summary['rss_average_mib']:.2f} / {summary['rss_max_mib']:.2f} MiB; target <10%: {verdict}.\n"
else:
    report=f"## WebKit engine process CPU/RSS ({when})\n\nNOT MEASURED: {summary.get('reason','unknown reason')}. macOS {platform.mac_ver()[0]}, model `{model}` provider `{provider}`; evidence `{folder}`.\n"
result={'status':status,'web_acceptance_exit':int(web_exit),'sampling':status,'samples':summary.get('samples',0),'cpu_average_percent':summary.get('cpu_average_percent'),'cpu_max_percent':summary.get('cpu_max_percent'),'rss_average_mib':summary.get('rss_average_mib'),'rss_max_mib':summary.get('rss_max_mib'),'process_breakdown':summary.get('process_breakdown',{}),'phase_measurements':summary.get('phase_measurements',{}),'evidence':str(folder),'web_evidence':web_evidence,'model':model,'provider':provider,'cpu_target':'<10%'}
(folder/'result.json').write_text(json.dumps(result,indent=2))
for name, values in summary.get('phase_measurements',{}).items():
    report += f"- {name}: {values['samples']} samples, CPU avg/max {values['cpu_average_percent']:.3f}/{values['cpu_max_percent']:.3f}%, RSS avg/max {values['rss_average_mib']:.2f}/{values['rss_max_mib']:.2f} MiB.\\n"
(folder/'measurements-report.md').write_text(report)
print(json.dumps(result,indent=2))
PY
cat "$evidence/web-acceptance.log"
[[ "$web_exit" -eq 0 && -s "$evidence/process-samples.jsonl" ]]