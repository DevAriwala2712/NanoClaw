import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


prep = load('prep', ROOT / 'scripts/prepare_quality_manifest.py')
models = load('fake_models', ROOT / 'scripts/dev/make_test_models.py')
q = prep.q
CHATML = "{% for m in messages %}{{'<|im_start|>' + m['role'] + '\\n' + m['content'] + '<|im_end|>\\n'}}{% endfor %}"
FAKE_TOKENIZER = '''import sys
args = sys.argv[1:]
if args == ['--version']:
    print('version: 0.7.0 (build 11669, commit 620d2225c)', file=sys.stderr); sys.exit(0)
text = open(args[args.index('-f') + 1]).read()
print(list(range(len(text) // 4)))
'''


def gguf(path, template, name='fake'):
    kvs = [models.kv_str('general.architecture', 'llama'), models.kv_str('tokenizer.ggml.model', 'gpt2'),
           models.kv_str('tokenizer.ggml.pre', 'smollm'), models.kv_str_array('tokenizer.ggml.tokens', ['a', 'b', 'c']),
           models.kv_str('tokenizer.chat_template', template), models.kv_str('general.name', name)]
    path.write_bytes(b'GGUF' + models.struct.pack('<IQQ', 3, 0, len(kvs)) + b''.join(kvs))


class PrepareManifest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        gguf(self.dir / 'large.gguf', CHATML, 'large')
        gguf(self.dir / 'small.gguf', CHATML, 'small')
        (self.dir / 'calibration.tsv').write_text('model\tctx\n')
        script = self.dir / 'tok.py'
        script.write_text(FAKE_TOKENIZER)
        self.tok = self.dir / 'llama-tokenize'
        self.tok.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
        self.tok.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def argv(self, out, split='development', *extra, complete=True):
        a = ['prepare', '--split', split, '--model', f'smollm2-1.7b-q4={self.dir / "large.gguf"}',
             '--model', f'smollm2-360m-q4={self.dir / "small.gguf"}', '--calibration', str(self.dir / 'calibration.tsv'),
             '--tokenizer', str(self.tok), '--llama-completion', '/home/ubuntu/llama-b11669/llama-completion',
             '--source-commit', 'a' * 40, '--out', str(self.dir / out), *extra]
        if complete:
            a += ['--hardware', 'test VM', '--authorization', 'unit test', '--repetitions', '3']
        return a

    def prepare(self, *args, **kw):
        prep.main(self.argv(*args, **kw))
        return json.loads((self.dir / args[0]).read_text())

    def test_development_sweep_manifest_is_freezable(self):
        m = self.prepare('dev.json', 'development', '--tuned-context', '1024')
        self.assertEqual(len(m['rendered_prompts']), 60)
        p = m['rendered_prompts'][0]
        case = next(c for c in q.load_cases(ROOT / 'evaluation/cases.jsonl') if c['id'] == p['case_id'])
        self.assertEqual(p['text'], prep.render(case['prompt']))
        self.assertEqual(p['tokens'], len(p['text']) // 4)
        self.assertEqual(m['tuned_context_by_cap'], {'1536': 1024, '2048': 1024, '3072': 1024})
        self.assertEqual(m['fixed_context'], 4096)
        self.assertEqual(m['models'][0]['tokenizer_id'], 'gpt2/smollm/vocab3/bos=None')
        self.assertIn('{prompt_file}', m['models'][0]['backend_arguments'])
        self.assertIn('build 11669', m['backend_build'])
        q.freeze_bundle(ROOT / 'evaluation/cases.jsonl', self.dir / 'dev.json', self.dir / 'bundle')

    def test_missing_human_fields_block_freeze(self):
        prep.main(self.argv('draft.json', 'development', '--tuned-context', '512', complete=False))
        draft = json.loads((self.dir / 'draft.json').read_text())
        self.assertIsNone(draft['authorization'])
        with self.assertRaises(ValueError):
            q.freeze_bundle(ROOT / 'evaluation/cases.jsonl', self.dir / 'draft.json', self.dir / 'bundle')

    def test_rejects_non_chatml_template_and_wrong_model_order(self):
        gguf(self.dir / 'small.gguf', '{{ messages }}')
        with self.assertRaises(SystemExit):
            prep.main(self.argv('bad.json'))
        gguf(self.dir / 'small.gguf', CHATML)
        a = self.argv('swap.json')
        i, j = a.index('--model') + 1, len(a) - a[::-1].index('--model')
        a[i], a[j] = a[j], a[i]
        with self.assertRaises(SystemExit):
            prep.main(a)

    def test_source_commit_reads_loose_and_packed_refs(self):
        git = self.dir / 'repo/.git'
        (git / 'refs/heads').mkdir(parents=True)
        (git / 'HEAD').write_text('ref: refs/heads/main\n')
        (git / 'packed-refs').write_text('# pack-refs\n' + 'b' * 40 + ' refs/heads/main\n')
        self.assertEqual(prep.source_commit(self.dir / 'repo'), 'b' * 40)
        (git / 'refs/heads/main').write_text('c' * 40 + '\n')
        self.assertEqual(prep.source_commit(self.dir / 'repo'), 'c' * 40)

    def summary(self, cap, ctx, correct, invalid=0, p50=100, provisional=False, policy='tuned_large'):
        path = self.dir / f's-{cap}-{ctx}-{correct}-{invalid}-{p50}.json'
        path.write_text(json.dumps({'bound': True, 'split': 'development', 'policy': policy, 'cap_mib': cap,
                                    'provisional': provisional, 'provisional_reason': None,
                                    'selections': {f'smollm2-1.7b-q4@{ctx}': 30},
                                    'correct_supported_tasks': correct, 'invalid_outputs': invalid,
                                    'forbidden_selections': 0, 'completion_latency_ms': {'p50': p50}}))
        return path

    def test_choose_tuned_follows_the_frozen_rule(self):
        paths = [self.summary(1536, 512, 10), self.summary(1536, 1024, 12),  # most correct wins
                 self.summary(2048, 512, 12, invalid=2), self.summary(2048, 1024, 12),  # fewer invalid
                 self.summary(3072, 1024, 12, p50=90), self.summary(3072, 2048, 12, p50=80),  # faster
                 self.summary(3072, 4096, 12, p50=80)]  # tie -> smaller context
        r = prep.choose_tuned(paths)
        self.assertEqual(r['tuned_context_by_cap'], {'1536': 1024, '2048': 1024, '3072': 2048})
        with self.assertRaises(ValueError):
            prep.choose_tuned([self.summary(1536, 512, 9, provisional=True)])
        with self.assertRaises(ValueError):
            prep.choose_tuned([self.summary(1536, 512, 8, policy='fixed_large')])

    def test_heldout_manifest_takes_tuned_selection_with_provenance(self):
        selection = self.dir / 'tuned.json'
        selection.write_text(json.dumps({'tuned_context_by_cap': {'1536': 512, '2048': 1024, '3072': 2048}}))
        m = self.prepare('heldout.json', 'heldout', '--tuned-selection', str(selection))
        self.assertEqual(m['development_results_sha256'], q.digest(selection))
        self.assertEqual({p['case_id'] for p in m['rendered_prompts']} <= {c['id'] for c in
                         q.load_cases(ROOT / 'evaluation/cases.jsonl') if c['split'] == 'heldout'}, True)
        q.freeze_bundle(ROOT / 'evaluation/cases.jsonl', self.dir / 'heldout.json', self.dir / 'bundle')


if __name__ == '__main__':
    unittest.main()
