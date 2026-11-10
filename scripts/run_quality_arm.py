#!/usr/bin/env python3
"""Run ONE policy arm at ONE memory cap for a frozen quality study.

Each request runs `nanoclaw-next bench --runs 1` in a fresh working directory.
With --launcher systemd it runs inside its own systemd user scope
(MemoryMax=cap, MemorySwapMax=0, OOMPolicy=continue). The scope records
memory.peak and the oom_kill delta. Output is records.jsonl plus run.json for
`evaluate_quality.py ingest`.

This script launches real inference when given real models. Run it only for an
authorized experiment. It never downloads anything, and it runs sudo only with
--drop-caches (intended for use inside a VM).
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
NOT_RUN = 'context_ineligible'
ENGINE_STATUSES = {'completed', 'backend_failed', 'backend_error', 'scheduler_refusal', 'deadline_exhausted'}
# Fixed arms disable adaptation: the scheduler sees "plenty" of memory and the
# kernel cap is the only limit. A single configured model leaves nothing to step down to.
UNLIMITED_MB = 1 << 30

SCOPE_SH = r'''set +e
run_dir="$1"; shift
if [ -n "$NANOCLAW_CGROUP_DIR" ]; then base="$NANOCLAW_CGROUP_DIR"
else base="/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)"; fi
cat "$base/memory.max" > "$run_dir/memory.max"
cat "$base/memory.events" > "$run_dir/events-before"
"$@" > "$run_dir/stdout" 2> "$run_dir/stderr"
code=$?
cat "$base/memory.events" > "$run_dir/events-after"
cat "$base/memory.peak" > "$run_dir/memory.peak"
exit "$code"
'''


def load_scorer(bundle):
    """Use the scorer frozen in the bundle, so the driver and ingest agree."""
    spec = importlib.util.spec_from_file_location('frozen_quality', Path(bundle) / 'evaluate_quality.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fail(message):
    raise ValueError(message)


def events(path):
    return {k: int(v) for k, v in (line.split() for line in Path(path).read_text().splitlines() if line.strip())}


def cgroup_measurements(run_dir):
    """memory.peak and the OOM-kill delta written by SCOPE_SH, or None if absent."""
    try:
        peak = int(Path(run_dir, 'memory.peak').read_text().split()[0])
        before, after = events(run_dir / 'events-before'), events(run_dir / 'events-after')
        return peak, after.get('oom_kill', 0) - before.get('oom_kill', 0)
    except (OSError, ValueError, IndexError):
        return None, None


def scope_argv(cap_mib, run_dir, command):
    run_dir = run_dir.resolve()
    return ['systemd-run', '--user', '--scope', '--quiet', '-p', f'MemoryMax={cap_mib}M',
            '-p', 'MemorySwapMax=0', '-p', 'OOMPolicy=continue',
            'bash', str(run_dir / 'scope.sh'), str(run_dir), *command]


def quote_template(arguments):
    for a in arguments:
        if "'" in a:
            fail('backend argument contains a single quote: ' + a)
    return ' '.join("'" + a + "'" for a in arguments)


def arm_plan(m, policy, cap):
    """Model IDs in the config, the requested context and whether adaptation is on."""
    large, small = m['models'][0]['id'], m['models'][1]['id']
    return {'fixed_large': ([large], m['fixed_context'], False),
            'fixed_small': ([small], m['fixed_context'], False),
            'tuned_large': ([large], m['tuned_context_by_cap'][str(cap)], False),
            'adaptive_input_gate': ([large, small], max(m['contexts']), True)}[policy]


def gate_min_ctx(q, m, case_id, model_ids, prompts):
    """Smallest study context every configured model's rendered prompt fits."""
    for ctx in sorted(m['contexts']):
        if all(q.eligible(prompts[case_id, mid]['tokens'], ctx, m['output_tokens']) for mid in model_ids):
            return ctx
    return None


def write_config(work, model_ids, models, paths, calibration, deadline_ms):
    arguments = {tuple(models[mid]['backend_arguments']) for mid in model_ids}
    if len(arguments) != 1:
        fail('one llm_cmd serves every configured model: backend_arguments must match')
    lines = ['llm_cmd=' + quote_template(list(arguments.pop())),
             'calibration_path=state/calibration.tsv', f'llm_timeout_ms={deadline_ms}']
    rank = len(model_ids)
    for mid in model_ids:
        lines.append(f'model={mid},{paths[mid]},{rank}')
        rank -= 1
    (work / 'state').mkdir(parents=True)
    shutil.copyfile(calibration, work / 'state/calibration.tsv')
    (work / 'nanoclaw-next.conf').write_text('\n'.join(lines) + '\n')


def run_request(args, q, m, case, rep, plan, prompts, models, paths):
    model_ids, ctx, adaptive = plan
    base = {'case_id': case['id'], 'repetition': rep}
    tokens = {mid: prompts[case['id'], mid]['tokens'] for mid in model_ids}
    if adaptive:
        min_ctx = gate_min_ctx(q, m, case['id'], model_ids, prompts)
    else:
        min_ctx = ctx if q.eligible(tokens[model_ids[0]], ctx, m['output_tokens']) else None
    if min_ctx is None:
        # Not run: record a configured model the input does not fit at this context.
        mid = next(x for x in model_ids if not q.eligible(tokens[x], ctx, m['output_tokens']))
        return dict(base, status=NOT_RUN, response=None, model_id=mid, context=ctx,
                    **bound_fields(mid, prompts, models, case['id']),
                    total_wall_ms=None, max_attempt_rss_bytes=None, cgroup_peak_bytes=None,
                    oom_kills=None, deadline_missed=None)
    work = args.out / 'requests' / f"{case['id']}-r{rep}"
    write_config(work, model_ids, models, paths, args.calibration, args.deadline_ms)
    command = [str(args.nanoclaw), 'bench', '--prompt', case['prompt'], '--runs', '1',
               '--ctx', str(ctx), '--min-ctx', str(min_ctx), '--tokens', str(m['output_tokens']),
               '--deadline-ms', str(args.deadline_ms), '--freeze-calibration', '--out', 'bench.csv']
    if not adaptive:
        command += ['--available-mb', str(UNLIMITED_MB)]
    if args.launcher == 'systemd':
        (work / 'scope.sh').write_text(SCOPE_SH)
        command = scope_argv(args.cap_mib, work, command)
    (work / 'argv.json').write_text(json.dumps(command, indent=2))
    if args.drop_caches:
        subprocess.run(['sudo', '-n', 'sh', '-c', 'sync; echo 3 > /proc/sys/vm/drop_caches'], check=True)
    started = time.monotonic()
    proc = subprocess.run(command, cwd=work, capture_output=True, timeout=args.deadline_ms / 1000 + 60)
    (work / 'driver-stdout').write_bytes(proc.stdout)
    (work / 'driver-stderr').write_bytes(proc.stderr)
    (work / 'driver.json').write_text(json.dumps({'exit_code': proc.returncode,
                                                  'scope_wall_ms': round((time.monotonic() - started) * 1000)}))
    try:
        request = json.loads((work / 'bench.csv.requests.jsonl').read_text().splitlines()[-1])
    except (OSError, IndexError, ValueError):
        fail(f"{work}: bench left no request record (exit {proc.returncode}); see driver-stderr")
    status = request['status']
    if status not in ENGINE_STATUSES:
        fail(f'{work}: unexpected engine status {status!r}')
    peak, oom = cgroup_measurements(work) if args.launcher == 'systemd' else (None, None)
    record = dict(base, status=status, response=request['response'] if status == 'completed' else None,
                  total_wall_ms=request['total_wall_ms'], max_attempt_rss_bytes=request['max_attempt_rss_bytes'],
                  cgroup_peak_bytes=peak, oom_kills=oom, deadline_missed=request['deadline_missed'])
    if status == 'scheduler_refusal' and not request['attempts']:
        if not adaptive:
            fail(f'{work}: the scheduler refused a fixed arm; check --deadline-ms and the calibration')
        return dict(record, model_id=None, context=None, prompt_tokens=None,
                    rendered_prompt_sha256=None, backend_arguments=None)
    if not request['attempts']:
        if adaptive:
            fail(f'{work}: {status} before any attempt; the adaptive choice is unknown')
        last = {'model': model_ids[0], 'ctx': ctx}  # a fixed arm has exactly one treatment
    else:
        last = request['attempts'][-1]
    if last['model'] not in model_ids:
        fail(f"{work}: engine ran unknown model {last['model']!r}")
    if not q.eligible(tokens[last['model']], last['ctx'], m['output_tokens']):
        fail(f"{work}: engine chose {last['model']}@{last['ctx']}, which the input does not fit")
    return dict(record, model_id=last['model'], context=last['ctx'],
                **bound_fields(last['model'], prompts, models, case['id']))


def bound_fields(mid, prompts, models, case_id):
    prompt = prompts[case_id, mid]
    return {'prompt_tokens': prompt['tokens'],
            'rendered_prompt_sha256': hashlib.sha256(prompt['text'].encode()).hexdigest(),
            'backend_arguments': models[mid]['backend_arguments']}


def parse_paths(values):
    paths = {}
    for v in values:
        mid, sep, path = v.partition('=')
        if not sep or not mid or not path:
            fail('--model takes ID=PATH: ' + v)
        paths[mid] = Path(path).resolve()
    return paths


def run_arm(args):
    q = load_scorer(args.bundle)
    cases, m, checksums_sha = q.load_bundle(args.bundle)
    if args.policy not in m['policies'] or args.cap_mib not in m['caps_mib']:
        fail('policy or cap is not in the manifest')
    if args.launcher == 'systemd' and platform.system() != 'Linux':
        fail('--launcher systemd needs Linux with a systemd user manager')
    if args.drop_caches and args.launcher != 'systemd':
        fail('--drop-caches is for Linux VM runs with --launcher systemd')
    models = {x['id']: x for x in m['models']}
    paths = parse_paths(args.model)
    plan = arm_plan(m, args.policy, args.cap_mib)
    for mid in plan[0]:
        if mid not in paths:
            fail('missing --model path for ' + mid)
        if q.digest(paths[mid]) != models[mid]['sha256']:
            fail('model file hash differs from the manifest: ' + mid)
        if q.digest(args.calibration) != models[mid]['calibration_sha256']:
            fail('calibration hash differs from the manifest for ' + mid)
    if args.out.exists():
        fail('refusing to overwrite ' + str(args.out))
    args.out.mkdir(parents=True)
    prompts = {(p['case_id'], p['model_id']): p for p in m['rendered_prompts']}
    selected = [c for c in cases if c['split'] == m['split']]
    if args.limit:
        selected = selected[:args.limit]
    records_path = args.out / 'records.jsonl'
    started = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    with records_path.open('x') as stream:
        for rep in range(1, m['repetitions'] + 1):
            for case in selected:
                r = run_request(args, q, m, case, rep, plan, prompts, models, paths)
                stream.write(json.dumps(r, sort_keys=True) + '\n')
                stream.flush()
                print(f"{case['id']} r{rep}: {r['status']} {r.get('model_id')}@{r.get('context')}", file=sys.stderr)
    run = {'schema_version': 1, 'policy': args.policy, 'cap_mib': args.cap_mib, 'split': m['split'],
           'repetitions': m['repetitions'], 'bundle_checksums_sha256': checksums_sha,
           'records_sha256': q.digest(records_path), 'launcher': args.launcher,
           'drop_caches': args.drop_caches, 'deadline_ms': args.deadline_ms, 'limit': args.limit,
           'nanoclaw_sha256': q.digest(args.nanoclaw), 'platform': platform.platform(),
           'started_utc': started, 'finished_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
    (args.out / 'run.json').write_text(json.dumps(run, indent=2) + '\n')
    return run


def build_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--policy', required=True)
    p.add_argument('--cap-mib', type=int, required=True)
    p.add_argument('--model', action='append', default=[], help='MODEL_ID=PATH.gguf (repeatable)')
    p.add_argument('--calibration', type=Path, required=True, help='frozen calibration.tsv')
    p.add_argument('--nanoclaw', type=Path, required=True, help='nanoclaw-next binary')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--launcher', choices=['systemd', 'none'], default='systemd',
                   help='none runs uncapped and leaves cgroup fields null (development only)')
    p.add_argument('--drop-caches', action='store_true', help='sudo -n drop_caches before each request')
    p.add_argument('--deadline-ms', type=int, default=120000)
    p.add_argument('--limit', type=int, default=0, help='first N cases only (smoke test; result stays provisional)')
    return p


def main(argv=None):
    p = build_parser()
    args = p.parse_args(argv)
    args.nanoclaw = args.nanoclaw.resolve()
    try:
        print(json.dumps(run_arm(args), indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as err:
        p.exit(2, f'error: {err}\n')


if __name__ == '__main__':
    main()
