#!/usr/bin/env python3
"""Two paired cold/warm llama-server probes in 1536 MiB cgroups on the M3 VM."""

import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request

import sys

sys.path.insert(0, str(Path.cwd() / 'bundles/smoke'))
from evaluate_quality import load_cases, score_response

HOME = Path.home()
BACKEND = HOME / 'llama-b11669'
MODEL = HOME / 'NanoClaw/models/SmolLM2-360M-Instruct-Q4_K_M.gguf'
CAP_BYTES = 1536 * 1024**2
CASES = ('uncertainty-01', 'diagnosis-04')
URL = 'http://127.0.0.1:18081'
OUT = Path('runs/persistent').resolve()


def save(path, data):
    path.write_text(json.dumps(data, indent=2) + '\n')


def wait_ready(process, deadline):
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f'llama-server exited {process.returncode}')
        try:
            with urllib.request.urlopen(URL + '/health', timeout=0.5) as response:
                if json.load(response)['status'] == 'ok':
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.05)
    raise TimeoutError('llama-server health check timed out')


def sample_cgroup(unit):
    cg = subprocess.check_output(
        ['systemctl', '--user', 'show', unit, '-p', 'ControlGroup', '--value'], text=True,
    ).strip()
    root = Path('/sys/fs/cgroup') / cg.lstrip('/')
    metrics = {name: int((root / name).read_text()) for name in (
        'memory.max', 'memory.swap.max', 'memory.current', 'memory.peak',
    )}
    metrics['memory.events'] = {k: int(v) for k, v in
                                (line.split() for line in (root / 'memory.events').read_text().splitlines())}
    rss = []
    for pid in (root / 'cgroup.procs').read_text().splitlines():
        status = Path(f'/proc/{pid}/status').read_text().splitlines()
        if status[0].split()[1].startswith('llama-server'):
            rss.extend(int(line.split()[1]) * 1024 for line in status if line.startswith('VmHWM:'))
    assert len(rss) == 1, rss
    metrics['server_peak_rss_bytes'] = rss[0]
    assert metrics['memory.max'] == CAP_BYTES and metrics['memory.swap.max'] == 0
    return metrics


def request(ids, timeout):
    payload = dict(prompt=ids, n_predict=128, temperature=0, seed=1, cache_prompt=False, stream=False)
    req = urllib.request.Request(URL + '/completion', data=json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'})
    started = time.monotonic()
    with urllib.request.urlopen(req, timeout=timeout) as response:
        data = json.load(response)
    return data, round((time.monotonic() - started) * 1000)


def run_case(case, rendered):
    name = case['id']
    folder = OUT / name
    folder.mkdir()
    prompt = folder / 'rendered-prompt.txt'
    prompt.write_text(rendered['text'])
    ids = json.loads(subprocess.check_output(
        [BACKEND / 'llama-tokenize', '-m', MODEL, '-f', prompt, '--ids', '--log-disable'], text=True,
    ).strip().splitlines()[-1])
    assert len(ids) == rendered['tokens']
    save(folder / 'prompt-token-ids.json', ids)
    unit = f'nanoclaw-m3-persistent-{name}.scope'
    command = [
        'systemd-run', '--user', '--scope', '--quiet', '--unit', unit,
        '-p', 'MemoryMax=1536M', '-p', 'MemorySwapMax=0', '-p', 'OOMPolicy=continue',
        str(BACKEND / 'llama-server'), '-m', str(MODEL), '-c', '8192', '-np', '1',
        '-ngl', '0', '-t', '4', '-tb', '4', '--fit', 'off', '--no-cache-prompt',
        '--host', '127.0.0.1', '--port', '18081',
    ]
    save(folder / 'argv.json', command)
    subprocess.run(['sudo', '-n', 'sh', '-c', 'sync; echo 3 > /proc/sys/vm/drop_caches'], check=True)
    started = time.monotonic()
    with (folder / 'server.log').open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_ready(process, started + 120)
            ready_ms = round((time.monotonic() - started) * 1000)
            cold, cold_ms = request(ids, max(1, 120 - (time.monotonic() - started)))
            cold_wall_ms = round((time.monotonic() - started) * 1000)
            save(folder / 'cold-response.json', cold)
            idle = sample_cgroup(unit)
            warm, warm_ms = request(ids, 120)
            save(folder / 'warm-response.json', warm)
            final = sample_cgroup(unit)
            save(folder / 'summary.json', {
                'case_id': name, 'prompt_tokens': len(ids), 'server_ready_ms': ready_ms,
                'cold_total_wall_ms': cold_wall_ms, 'cold_http_wall_ms': cold_ms,
                'warm_http_wall_ms': warm_ms, 'idle_after_cold': idle, 'after_warm': final,
                'cold_score': score_response(case, cold['content']),
                'warm_score': score_response(case, warm['content']),
            })
            assert cold['timings']['prompt_n'] == warm['timings']['prompt_n'] == len(ids)
            assert final['memory.events']['oom_kill'] == 0
            print(name, ready_ms, cold_wall_ms, warm_ms, flush=True)
        finally:
            subprocess.run(['systemctl', '--user', 'stop', unit], capture_output=True)
            process.wait(timeout=15)


def main():
    assert os.uname().sysname == 'Linux'
    OUT.mkdir()
    bundle = Path('bundles/smoke')
    cases = {case['id']: case for case in load_cases(bundle / 'cases.jsonl')}
    manifest = json.loads((bundle / 'manifest.json').read_text())
    prompts = {p['case_id']: p for p in manifest['rendered_prompts']
               if p['model_id'] == 'smollm2-360m-q4'}
    for name in CASES:
        run_case(cases[name], prompts[name])


if __name__ == '__main__':
    main()
