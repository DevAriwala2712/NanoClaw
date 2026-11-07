#!/usr/bin/env python3
"""Prepare quality-study manifests and pick the tuned baseline. Never runs inference.

prepare        Fill a manifest from the template: model, calibration and case
               hashes, GGUF tokenizer identity, rendered prompts, and per-model
               token counts from the pinned `llama-tokenize`. That tool loads
               only the vocabulary.
choose-tuned   Apply the frozen rule to development-sweep ingest summaries and
               write the tuned context per cap for the held-out manifest.

Fields this tool cannot know (hardware, authorization, repetitions) come from
flags. They stay null when omitted, so `evaluate_quality.py freeze` refuses.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
spec = importlib.util.spec_from_file_location('quality', HERE / 'evaluate_quality.py')
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)

# llama-completion runs with jinja disabled (its default) and no -sys. The
# built-in chatml template then renders a single user turn plus the generation prompt.
RENDERING = 'llama.cpp built-in chatml (jinja disabled, no system prompt), single user turn + generation prompt'
CHATML_MARKERS = ('<|im_start|>', '<|im_end|>')
DEFAULT_ORDERING = ('caps ascending; within a cap, policies in manifest order; within a run, '
                    'repetitions outer and cases in suite order')
DEFAULT_CACHE = 'sync; echo 3 > /proc/sys/vm/drop_caches inside the VM before every request (--drop-caches)'

TUNED_RULE = ('most correct supported tasks, then fewest invalid or forbidden outputs, '
              'then lowest median completion latency, then smallest context')

_FMT = {0: 'B', 1: 'b', 2: 'H', 3: 'h', 4: 'I', 5: 'i', 6: 'f', 7: '?', 10: 'Q', 11: 'q', 12: 'd'}


def gguf_metadata(path, wanted):
    """Read selected GGUF metadata. Large arrays are skipped and return their length."""
    def string(f):
        (n,) = struct.unpack('<Q', f.read(8))
        return f.read(n).decode('utf-8')

    def value(f, kind, keep):
        if kind == 8:
            return string(f)
        if kind == 9:
            inner, n = struct.unpack('<IQ', f.read(12))
            items = [value(f, inner, keep) for _ in range(n)]
            return items if keep else n
        fmt = '<' + _FMT[kind]
        return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]

    out = {}
    with open(path, 'rb') as f:
        q.require(f.read(4) == b'GGUF', f'{path}: not a GGUF file')
        _version, _tensors, count = struct.unpack('<IQQ', f.read(20))
        for _ in range(count):
            key = string(f)
            (kind,) = struct.unpack('<I', f.read(4))
            v = value(f, kind, keep=key in wanted)
            if key in wanted or key == 'tokenizer.ggml.tokens':
                out[key] = v
    return out


def render(prompt):
    return '<|im_start|>user\n' + prompt + '<|im_end|>\n<|im_start|>assistant\n'


def count_tokens(tokenizer, model_path, text):
    with tempfile.NamedTemporaryFile('w', suffix='.txt', delete=False) as stream:
        stream.write(text)
    try:
        p = subprocess.run([str(tokenizer), '-m', str(model_path), '-f', stream.name, '--ids', '--log-disable'],
                           capture_output=True, text=True, timeout=120)
    finally:
        Path(stream.name).unlink()
    q.require(p.returncode == 0, f'llama-tokenize failed: {p.stderr.strip()[-400:]}')
    ids = json.loads(p.stdout.strip().splitlines()[-1])
    q.require(isinstance(ids, list) and ids and all(type(i) is int for i in ids), 'unexpected llama-tokenize output')
    return len(ids)


def backend_version(binary):
    p = subprocess.run([str(binary), '--version'], capture_output=True, text=True, timeout=60)
    text = (p.stdout + p.stderr).strip()
    q.require('version:' in text, f'cannot read {binary} --version')
    return ' '.join(text.split())


def backend_arguments(llama, threads):
    return [llama, '-m', '{model}', '-c', '{ctx}', '-n', '{n}', '-f', '{prompt_file}', '-cnv', '-st',
            '--no-display-prompt', '--temp', '0', '-s', '1', '-ngl', '0', '--simple-io',
            '-t', str(threads), '-tb', str(threads), '--fit', 'off']


def source_commit(root=ROOT):
    """Read HEAD from .git without invoking git."""
    git = root / '.git'
    head = (git / 'HEAD').read_text().strip()
    if not head.startswith('ref: '):
        return head
    ref = head[5:]
    loose = git / ref
    if loose.exists():
        return loose.read_text().strip()
    for line in (git / 'packed-refs').read_text().splitlines():
        if line.endswith(' ' + ref):
            return line.split()[0]
    raise ValueError('cannot resolve ' + ref)


def prepare(args):
    cases = q.load_cases(args.cases)
    m = q.strict_json(args.template.read_text())
    q.validate_manifest(m, cases)
    q.require(len(args.model) == 2, 'pass --model for the large then the small model')
    m['split'] = args.split
    m['fixed_context'] = args.fixed_context
    m['repetitions'] = args.repetitions
    m['hardware'] = args.hardware
    m['authorization'] = args.authorization
    m['threads'] = args.threads
    m['sampling'] = 'greedy: --temp 0 -s 1, ' + str(m['output_tokens']) + ' output tokens'
    m['cache_procedure'] = args.cache_procedure
    m['ordering'] = args.ordering
    m['source_commit'] = args.source_commit or source_commit()
    m['backend_build'] = backend_version(args.tokenizer)
    m['cases_sha256'] = q.digest(args.cases)
    m['rendering'] = RENDERING
    calibration_sha = q.digest(args.calibration)
    wanted = {'tokenizer.chat_template', 'tokenizer.ggml.model', 'tokenizer.ggml.pre', 'tokenizer.ggml.add_bos_token'}
    paths = {}
    for model, spec_ in zip(m['models'], args.model):
        mid, _, path = spec_.partition('=')
        q.require(mid == model['id'], f"--model order must follow the template: expected {model['id']}")
        meta = gguf_metadata(path, wanted)
        template = meta.get('tokenizer.chat_template', '')
        q.require(all(k in template for k in CHATML_MARKERS), mid + ': chat template is not ChatML; renderer does not apply')
        model.update(sha256=q.digest(path),
                     tokenizer_id='%s/%s/vocab%d/bos=%s' % (meta.get('tokenizer.ggml.model'), meta.get('tokenizer.ggml.pre'),
                                                           meta['tokenizer.ggml.tokens'], meta.get('tokenizer.ggml.add_bos_token')),
                     template_sha256=hashlib.sha256(template.encode()).hexdigest(),
                     calibration_sha256=calibration_sha,
                     backend_arguments=backend_arguments(args.llama_completion, args.threads))
        paths[mid] = path
    source = f"{Path(args.tokenizer).name} --ids ({m['backend_build']}); special tokens parsed, model BOS setting"
    m['rendered_prompts'] = []
    for c in cases:
        if c['split'] != args.split:
            continue
        for model in m['models']:
            text = render(c['prompt'])
            m['rendered_prompts'].append({'case_id': c['id'], 'model_id': model['id'], 'text': text,
                                          'tokens': count_tokens(args.tokenizer, paths[model['id']], text),
                                          'token_count_source': source})
    if args.tuned_context is not None:
        q.require(args.split == 'development', '--tuned-context is for development-sweep manifests')
        m['tuned_context_by_cap'] = {str(cap): args.tuned_context for cap in m['caps_mib']}
    if args.tuned_selection:
        q.require(args.split == 'heldout', '--tuned-selection is for the held-out manifest')
        selection = q.strict_json(args.tuned_selection.read_text())
        m['tuned_context_by_cap'] = selection['tuned_context_by_cap']
        m['development_results_sha256'] = q.digest(args.tuned_selection)
    q.validate_manifest(m, cases)
    missing = [k for k in ('hardware', 'authorization', 'repetitions') if m.get(k) in (None, '')]
    if not m['tuned_context_by_cap']:
        missing.append('tuned_context_by_cap')
    return m, missing


def median_latency(summary):
    p50 = summary['completion_latency_ms']['p50']
    return float('inf') if p50 is None else p50


def choose_tuned(paths, allow_provisional=False):
    """Pick one context per cap by TUNED_RULE (evaluation/README.md)."""
    by_cap = {}
    for path in paths:
        s = q.strict_json(Path(path).read_text())
        q.require(s.get('bound') is True and s.get('split') == 'development', f'{path}: not a bound development summary')
        q.require(s.get('policy') == 'tuned_large', f'{path}: the sweep runs tuned_large')
        q.require(allow_provisional or not s['provisional'], f"{path}: provisional ({s['provisional_reason']})")
        launched = [k for k in s['selections'] if k != 'refused']
        q.require(len(launched) <= 1, f'{path}: a sweep run must use one context')
        ctx = int(launched[0].rsplit('@', 1)[1]) if launched else None
        q.require(ctx is not None, f'{path}: nothing launched; cannot tell which context it swept')
        entry = {'context': ctx, 'summary': str(path), 'summary_sha256': q.digest(path),
                 'correct_supported_tasks': s['correct_supported_tasks'],
                 'invalid_or_forbidden': s['invalid_outputs'] + s['forbidden_selections'],
                 'median_completion_ms': s['completion_latency_ms']['p50']}
        q.require(ctx not in {e['context'] for e, _ in by_cap.get(s['cap_mib'], [])}, f'{path}: duplicate context')
        by_cap.setdefault(s['cap_mib'], []).append((entry, s))
    chosen = {}
    for cap, entries in sorted(by_cap.items()):
        best = min(entries, key=lambda es: (-es[1]['correct_supported_tasks'],
                                            es[1]['invalid_outputs'] + es[1]['forbidden_selections'],
                                            median_latency(es[1]), es[0]['context']))
        chosen[str(cap)] = best[0]['context']
    return {'schema_version': 1, 'rule': TUNED_RULE, 'allow_provisional': allow_provisional, 'tuned_context_by_cap': chosen,
            'candidates': {str(cap): [e for e, _ in sorted(es, key=lambda x: x[0]['context'])]
                           for cap, es in sorted(by_cap.items())}}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='command', required=True)
    a = sub.add_parser('prepare')
    a.add_argument('--template', type=Path, default=ROOT / 'evaluation/manifest.template.json')
    a.add_argument('--cases', type=Path, default=ROOT / 'evaluation/cases.jsonl')
    a.add_argument('--split', choices=['development', 'heldout'], required=True)
    a.add_argument('--model', action='append', default=[], help='ID=PATH.gguf, large model first')
    a.add_argument('--calibration', type=Path, required=True)
    a.add_argument('--tokenizer', type=Path, required=True, help='llama-tokenize from the pinned build')
    a.add_argument('--llama-completion', required=True, help='llama-completion path ON THE TARGET machine')
    a.add_argument('--threads', type=int, default=4)
    a.add_argument('--fixed-context', type=int, default=4096)
    a.add_argument('--repetitions', type=int)
    a.add_argument('--hardware')
    a.add_argument('--authorization')
    a.add_argument('--source-commit')
    a.add_argument('--cache-procedure', default=DEFAULT_CACHE)
    a.add_argument('--ordering', default=DEFAULT_ORDERING)
    a.add_argument('--tuned-context', type=int, help='development sweep: this context at every cap')
    a.add_argument('--tuned-selection', type=Path, help='held-out: output of choose-tuned')
    a.add_argument('--out', type=Path, required=True)
    c = sub.add_parser('choose-tuned')
    c.add_argument('summaries', nargs='+', type=Path)
    c.add_argument('--allow-provisional', action='store_true', help='smoke tests only')
    c.add_argument('--out', type=Path, required=True)
    args = p.parse_args(argv)
    try:
        if args.command == 'prepare':
            m, missing = prepare(args)
            with args.out.open('x') as stream:
                stream.write(json.dumps(m, indent=2) + '\n')
            print(json.dumps({'out': str(args.out), 'rendered_prompts': len(m['rendered_prompts']),
                              'max_prompt_tokens': max(x['tokens'] for x in m['rendered_prompts']),
                              'unresolved_for_freeze': missing}, indent=2))
        else:
            result = choose_tuned(args.summaries, args.allow_provisional)
            with args.out.open('x') as stream:
                stream.write(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result['tuned_context_by_cap'], indent=2))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as err:
        p.exit(2, f'error: {err}\n')


if __name__ == '__main__':
    main()
