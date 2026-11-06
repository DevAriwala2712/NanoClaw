#!/usr/bin/env python3
"""One-off M2 VM measurement driver; never substitutes simulated memory for cgroups."""
import csv, hashlib, json, math, os, platform, subprocess, time
from pathlib import Path

root = Path('/home/ubuntu/NanoClaw')
os.chdir(root)
out = root / 'state/m2-vm'
out.mkdir(exist_ok=True)
prompt = 'Explain what swap memory is in two sentences.'
llama = '/home/ubuntu/llama-b11669/llama-completion'
config = root / 'nanoclaw-next.conf'
text = config.read_text()
if '--fit off' not in text:
    text = text.replace('--simple-io', '--simple-io -t 4 -tb 4 --fit off')
config.write_text(text)
(out / 'config.txt').write_text(text)
(out / 'calibration-before.tsv').write_text((root/'state/calibration.tsv').read_text())
(out / 'prompt.txt').write_text(prompt)
metadata = {'date_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'platform': platform.platform(), 'cpus': os.cpu_count(), 'cap_bytes': 1536*1024*1024, 'context': 4096, 'tokens': 128, 'runs_per_strategy': 5, 'prompt': prompt, 'order': 'alternating baseline/adaptive', 'cache_policy': 'sync + drop_caches=3 inside VM before each run', 'llama_version': subprocess.run([llama, '--version'],capture_output=True,text=True).stderr}
metadata['model_sha256'] = {p.name:hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in (root/'models').glob('*.gguf')}
(out/'metadata.json').write_text(json.dumps(metadata,indent=2))
scope_script = '''
set +e
run_dir="$1"
shift
cg=$(cut -d: -f3 /proc/self/cgroup)
base="/sys/fs/cgroup$cg"
cat "$base/memory.max" > "$run_dir/memory.max"
cat "$base/memory.swap.max" > "$run_dir/memory.swap.max"
cat "$base/memory.events" > "$run_dir/events-before"
/usr/bin/time -f '%M' -o "$run_dir/max-rss-kib" "$@" > "$run_dir/stdout" 2> "$run_dir/stderr"
code=$?
cat "$base/memory.events" > "$run_dir/events-after"
cat "$base/memory.peak" > "$run_dir/memory.peak"
exit "$code"
'''
(out/'scope.sh').write_text(scope_script)
rows = []
for i in range(1,6):
    for kind in ('baseline','adaptive'):
        run_dir=out/f'{kind}-{i}'
        run_dir.mkdir(exist_ok=True)
        if kind=='baseline':
            cmd=[llama,'-m',str(root/'models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf'),'-c','4096','-n','128','-p',prompt,'-cnv','-st','--no-display-prompt','--temp','0','-s','1','-ngl','0','--simple-io','-t','4','-tb','4','--fit','off']
        else:
            cmd=[str(root/'bin/nanoclaw-next'),'bench','--prompt',prompt,'--runs','1','--ctx','4096','--tokens','128','--out',str(run_dir/'bench.csv')]
        argv=['systemd-run','--user','--scope','--quiet','-p','MemoryMax=1536M','-p','MemorySwapMax=0','-p','OOMPolicy=continue','bash',str(out/'scope.sh'),str(run_dir)]+cmd
        (run_dir/'argv.json').write_text(json.dumps(argv,indent=2))
        subprocess.run(['sudo','sh','-c','sync; echo 3 > /proc/sys/vm/drop_caches'],check=True)
        started=time.monotonic()
        p=subprocess.run(argv,capture_output=True,text=True,timeout=150)
        wall=round((time.monotonic()-started)*1000)
        (run_dir/'scope-stderr').write_text(p.stderr)
        before=dict(line.split() for line in (run_dir/'events-before').read_text().splitlines())
        after=dict(line.split() for line in (run_dir/'events-after').read_text().splitlines())
        ok=p.returncode==0
        model='smollm2-1.7b'
        child_rss=''
        child_wall=''
        if kind=='adaptive':
            bench=list(csv.DictReader((run_dir/'bench.csv').open()))[0]
            ok=ok and bench['ok']=='1'
            model=bench['model']
            child_rss=bench['peak_rss_mb']
            child_wall=bench['wall_ms']
        rss=int((run_dir/'max-rss-kib').read_text().splitlines()[-1])
        row={'strategy':kind,'run':i,'ok':int(ok),'exit':p.returncode,'model':model,'end_to_end_ms':wall,'command_peak_rss_kib':rss,'cgroup_peak_bytes':int((run_dir/'memory.peak').read_text()),'oom_kills':int(after['oom_kill'])-int(before['oom_kill']),'child_wall_ms':child_wall,'child_peak_rss_mib':child_rss}
        rows.append(row)
        print(json.dumps(row),flush=True)
with (out/'comparison.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=list(rows[0]))
    w.writeheader();w.writerows(rows)
summary={}
for kind in ('baseline','adaptive'):
    rs=[r for r in rows if r['strategy']==kind]
    walls=sorted(r['end_to_end_ms'] for r in rs if r['ok'])
    all_walls=sorted(r['end_to_end_ms'] for r in rs)
    summary[kind]={'success':sum(r['ok'] for r in rs),'runs':len(rs),'success_p50_ms':walls[math.ceil(.5*len(walls))-1] if walls else None,'success_p95_ms':walls[math.ceil(.95*len(walls))-1] if walls else None,'all_attempt_p50_ms':all_walls[math.ceil(.5*len(all_walls))-1],'all_attempt_p95_ms':all_walls[math.ceil(.95*len(all_walls))-1],'max_command_peak_rss_kib':max(r['command_peak_rss_kib'] for r in rs),'max_cgroup_peak_bytes':max(r['cgroup_peak_bytes'] for r in rs),'oom_kills':sum(r['oom_kills'] for r in rs)}
(out/'summary.json').write_text(json.dumps(summary,indent=2))
print(json.dumps(summary,indent=2),flush=True)
