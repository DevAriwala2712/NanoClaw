"""Stands in for `nanoclaw-next bench --runs 1`; no inference.

FAKE_MODE: ok | oom_large | refuse. FAKE_RESPONSES: JSON file mapping prompt -> response.
Writes the same bench.csv.requests.jsonl fields the real engine writes.
"""
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
assert args[0] == 'bench'
flag = {args[i]: args[i + 1] for i in range(1, len(args) - 1) if args[i].startswith('--') and not args[i + 1].startswith('--')}
models = [line.split('=', 1)[1].split(',')[0] for line in Path('nanoclaw-next.conf').read_text().splitlines()
          if line.startswith('model=')]
Path('argv-seen.json').write_text(json.dumps(args))
mode = os.environ.get('FAKE_MODE', 'ok')
responses = json.loads(Path(os.environ['FAKE_RESPONSES']).read_text()) if 'FAKE_RESPONSES' in os.environ else {}
ctx, min_ctx = int(flag['--ctx']), int(flag['--min-ctx'])
adaptive = '--available-mb' not in flag


def attempt(model, c, outcome='exited', signal=None):
    return {'model': model, 'ctx': c, 'outcome': outcome, 'exit_code': 0 if outcome == 'exited' else None,
            'signal': signal, 'wall_ms': 40, 'peak_rss_bytes': 5 * 10 ** 8, 'stdout': '', 'stderr': ''}


attempts, status = [], 'completed'
if mode == 'refuse':
    status = 'scheduler_refusal'
elif mode == 'oom_large':
    attempts.append(attempt(models[0], ctx, 'signaled', 9))
    if len(models) > 1:
        attempts.append(attempt(models[1], min_ctx if adaptive else ctx))
    else:
        status = 'backend_failed'
else:
    attempts.append(attempt(models[0], min_ctx if adaptive else ctx))
record = {'schema_version': 2, 'run': 1, 'status': status, 'error_name': None, 'prompt': flag['--prompt'],
          'response': responses.get(flag['--prompt'], '{}') if status == 'completed' else None,
          'total_wall_ms': 50 * max(1, len(attempts)), 'deadline_ms': int(flag['--deadline-ms']),
          'deadline_missed': False, 'max_attempt_rss_bytes': 5 * 10 ** 8 if attempts else None,
          'attempts': attempts, 'calibration_frozen': '--freeze-calibration' in args}
Path(flag['--out'] + '.requests.jsonl').write_text(json.dumps(record) + '\n')
