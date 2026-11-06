#!/usr/bin/env python3
"""M2 measurement experiment: six real models, independent held-out contexts."""
import csv, hashlib, json, math, os, platform, re, subprocess, time
from pathlib import Path

root=Path('/home/ubuntu/NanoClaw');os.chdir(root)
out=root/'state/m2-grid-2026-11-06';out.mkdir(exist_ok=True)
models=json.loads((root/'state/grid-manifest.json').read_text())
(out/'models.json').write_text(json.dumps(models,indent=2)+'\n')
prompt='Explain what swap memory is in two sentences.'
llama='/home/ubuntu/llama-b11669/llama-completion'
base=root/'bin/nanoclaw-next'
meta={'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'platform':platform.platform(),'vcpus':os.cpu_count(),'vm_ram_gib':8,'per_run_cap_bytes':6*1024**3,'cache_policy':'sync + drop_caches=3 inside VM before calibration and each held-out run','calibration_contexts':[512,4096],'heldout_contexts':[1024,2048,8192],'repetitions':3,'max_new_tokens':64,'prompt':prompt,'source_commit':'7d5643b','zig':'0.15.2','llama_release':'b11669','order':'model, then held-out context, then repeat; all sequential'}
if not (out/'metadata.json').exists(): (out/'metadata.json').write_text(json.dumps(meta,indent=2)+'\n')
scope='''set +e
run_dir="$1"; shift
cg=$(cut -d: -f3 /proc/self/cgroup)
base="/sys/fs/cgroup$cg"
cat "$base/memory.max" > "$run_dir/memory.max"
cat "$base/memory.swap.max" > "$run_dir/memory.swap.max"
cat "$base/memory.events" > "$run_dir/events-before"
/usr/bin/time -f '%M,%e' -o "$run_dir/time.csv" "$@" > "$run_dir/stdout" 2> "$run_dir/stderr"
code=$?
cat "$base/memory.events" > "$run_dir/events-after"
cat "$base/memory.peak" > "$run_dir/memory.peak"
exit "$code"
'''
(out/'scope.sh').write_text(scope)
def execute(folder,cmd,cwd):
    folder.mkdir(exist_ok=True)
    argv=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=6G','-p','MemorySwapMax=0','-p','OOMPolicy=continue','bash',str(out/'scope.sh'),str(folder)]+cmd
    (folder/'argv.json').write_text(json.dumps(argv,indent=2)+'\n')
    subprocess.run(['sudo','sh','-c','sync; echo 3 > /proc/sys/vm/drop_caches'],check=True)
    started=time.monotonic()
    p=subprocess.run(argv,cwd=cwd,capture_output=True,text=True,timeout=180)
    elapsed=round((time.monotonic()-started)*1000)
    (folder/'scope-stderr').write_text(p.stderr)
    assert (folder/'memory.max').read_text().strip()==str(6*1024**3)
    before=dict(line.split() for line in (folder/'events-before').read_text().splitlines())
    after=dict(line.split() for line in (folder/'events-after').read_text().splitlines())
    oom=int(after['oom_kill'])-int(before['oom_kill'])
    return p.returncode,elapsed,oom

rows=[]
for m in models:
    model=root/'models'/m['filename']
    assert model.stat().st_size==m['size_bytes']
    assert hashlib.file_digest(model.open('rb'),'sha256').hexdigest()==m['sha256']
    folder=out/m['name'];folder.mkdir(exist_ok=True)
    config='\n'.join(['desired_ctx=4096','min_ctx=512','memory_headroom_mb=256','llm_timeout_ms=120000','calibration_path='+str(folder/'calibration.tsv'),'llm_cmd='+llama+' -m {model} -c {ctx} -n {n} -f {prompt_file} -cnv -st --no-display-prompt --temp 0 -s 1 -ngl 0 --simple-io -t 4 -tb 4 --fit off','model='+m['name']+','+str(model)+',3',''])
    (folder/'nanoclaw-next.conf').write_text(config)
    if not (folder/'calibration-complete.json').exists():
        if (folder/'calibration.tsv').exists():
            raise RuntimeError('Partial calibration: inspect before resuming '+str(folder))
        code,wall,oom=execute(folder/'calibrate',[str(base),'calibrate','--prompt',prompt,'--tokens','64'],folder)
        assert code==0 and oom==0,(m['name'],'calibration failed',code,oom)
        samples=list(csv.reader((folder/'calibration.tsv').open(),delimiter='\t'))
        assert len(samples)==2 and {int(s[1]) for s in samples}=={512,4096}
        (folder/'calibration-complete.json').write_text(json.dumps({'exit':code,'end_to_end_ms':wall,'oom_kills':oom}))
    samples=list(csv.reader((folder/'calibration.tsv').open(),delimiter='\t'))
    overhead=max(32*1024**2,max(max(0,int(s[2])-m['size_bytes']-m['kv_bytes_per_token']*int(s[1])) for s in samples))
    probe=subprocess.run([str(base),'probe'],cwd=folder,capture_output=True,text=True,check=True)
    (folder/'probe.log').write_text(probe.stderr+probe.stdout)
    kv_kib=m['kv_bytes_per_token']//1024
    assert f'KV {kv_kib} KB/token' in probe.stderr,(m['name'],'GGUF KV metadata differs')
    for ctx in (1024,2048,8192):
        prediction=m['size_bytes']+m['kv_bytes_per_token']*ctx+overhead
        plan=subprocess.run([str(base),'plan','--ctx',str(ctx),'--min-ctx',str(ctx),'--tokens','64','--available-mb','8192'],cwd=folder,capture_output=True,text=True,check=True)
        (folder/f'plan-{ctx}.log').write_text(plan.stderr+plan.stdout)
        planned=re.search(r'\[plan\] run .* at ctx (\d+) \(est\. (\d+) MB\)',plan.stderr)
        assert planned and int(planned[1])==ctx and int(planned[2])==prediction//1024**2,(m['name'],ctx,'formula/production plan mismatch',plan.stderr)
        for repeat in range(1,4):
            sample_dir=folder/f'ctx-{ctx}-run-{repeat}'
            sample_dir.mkdir(exist_ok=True)
            if (sample_dir/'result.json').exists():
                row=json.loads((sample_dir/'result.json').read_text())
            else:
                cmd=[llama,'-m',str(model),'-c',str(ctx),'-n','64','-p',prompt,'-cnv','-st','--no-display-prompt','--temp','0','-s','1','-ngl','0','--simple-io','-t','4','-tb','4','--fit','off']
                code,wall,oom=execute(sample_dir,cmd,folder)
                perf=(sample_dir/'time.csv').read_text().splitlines()[-1].split(',')
                measured=int(perf[0])*1024
                output=(sample_dir/'stdout').read_text()
                generated=0
                for line in (sample_dir/'stderr').read_text().splitlines():
                    if 'eval time' in line and 'prompt eval time' not in line:
                        match=re.search(r'/\s*(\d+)\s+(?:tokens|runs)',line)
                        if match: generated=int(match[1])
                row={'model':m['name'],'family':m['family'],'quant':m['quant'],'ctx':ctx,'repeat':repeat,'exit':code,'oom_kills':oom,'predicted_bytes':prediction,'measured_bytes':measured,'error_pct':round((prediction-measured)/measured*100,4),'end_to_end_ms':wall,'cgroup_peak_bytes':int((sample_dir/'memory.peak').read_text()),'output_bytes':len(output.encode()),'generated_tokens':generated}
                assert code==0 and oom==0 and row['output_bytes']>0 and generated>0,row
                (sample_dir/'result.json').write_text(json.dumps(row,indent=2)+'\n')
            rows.append(row)
            print(json.dumps(row),flush=True)
    print('Completed '+m['name'],flush=True)
with (out/'measurements.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
summary=[]
for m in models:
    rs=[r for r in rows if r['model']==m['name']]
    absolute=[abs(r['error_pct']) for r in rs]
    summary.append({'model':m['name'],'samples':len(rs),'max_absolute_error_pct':max(absolute),'mean_absolute_error_pct':round(sum(absolute)/len(absolute),4),'all_under_10pct':all(e<10 for e in absolute),'oom_kills':sum(r['oom_kills'] for r in rs)})
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2),flush=True)
