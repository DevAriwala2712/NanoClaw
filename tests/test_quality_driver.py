import importlib.util
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


q = load('quality', ROOT / 'scripts/evaluate_quality.py')
driver = load('driver', ROOT / 'scripts/run_quality_arm.py')
ingestion = load('ingestion_tests', ROOT / 'tests/test_run_ingestion.py')
LARGE, SMALL = ingestion.LARGE, ingestion.SMALL
ARGS = ['{model}', '-c', '{ctx}', '-n', '{n}', '-f', '{prompt_file}']


class QualityDriver(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.cases = q.load_cases(ingestion.CASES_PATH)
        self.heldout = [c for c in self.cases if c['split'] == 'heldout']
        for name in ('large.gguf', 'small.gguf', 'calibration.tsv'):
            (self.dir / name).write_text('fake ' + name)
        self.manifest = ingestion.ready_manifest(self.cases)
        for model, name in zip(self.manifest['models'], ('large.gguf', 'small.gguf')):
            model.update(sha256=q.digest(self.dir / name), backend_arguments=ARGS,
                         calibration_sha256=q.digest(self.dir / 'calibration.tsv'))
        self.bundle = self.freeze(self.manifest)
        responses = {c['prompt']: json.dumps(c['expected'][0]) for c in self.cases}
        (self.dir / 'responses.json').write_text(json.dumps(responses))
        self.fake = self.dir / 'nanoclaw-next'
        self.fake.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT}/tests/fixtures/fake_nanoclaw.py" "$@"\n')
        self.fake.chmod(0o755)
        self.env = mock.patch.dict(os.environ, {'FAKE_RESPONSES': str(self.dir / 'responses.json')})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def freeze(self, manifest, name='bundle'):
        (self.dir / (name + '.json')).write_text(json.dumps(manifest))
        q.freeze_bundle(ingestion.CASES_PATH, self.dir / (name + '.json'), self.dir / name)
        return self.dir / name

    def run_arm(self, policy='fixed_large', cap=2048, out='out', extra=(), bundle=None):
        argv = ['--bundle', str(bundle or self.bundle), '--policy', policy, '--cap-mib', str(cap),
                '--model', f'{LARGE}={self.dir / "large.gguf"}', '--model', f'{SMALL}={self.dir / "small.gguf"}',
                '--calibration', str(self.dir / 'calibration.tsv'), '--nanoclaw', str(self.fake),
                '--out', str(self.dir / out), '--launcher', 'none', *extra]
        args = driver.build_parser().parse_args(argv)
        args.nanoclaw = args.nanoclaw.resolve()
        driver.run_arm(args)
        out_dir = self.dir / out
        records = [json.loads(l) for l in (out_dir / 'records.jsonl').read_text().splitlines()]
        return out_dir, records

    def ingest(self, out_dir, bundle=None):
        return q.ingest(bundle or self.bundle, out_dir / 'run.json', out_dir / 'records.jsonl')

    def test_fixed_arm_records_bind_but_stay_provisional_without_cgroup(self):
        out, records = self.run_arm()
        self.assertEqual(len(records), 30)
        s = self.ingest(out)
        self.assertEqual(s['selections'], {LARGE + '@1024': 30})
        self.assertEqual(s['correct_supported_tasks'] + s['correct_refusal_tasks'], 30)
        self.assertTrue(s['provisional'])
        self.assertIn('cgroup_peak_bytes', s['provisional_reason'])
        self.assertFalse(s['quality_floor_passed'])
        seen = json.loads((out / 'requests' / (self.heldout[0]['id'] + '-r1') / 'argv-seen.json').read_text())
        self.assertIn('--available-mb', seen)
        self.assertIn('--freeze-calibration', seen)
        config = (out / 'requests' / (self.heldout[0]['id'] + '-r1') / 'nanoclaw-next.conf').read_text()
        self.assertIn(f'model={LARGE},', config)
        self.assertNotIn(SMALL, config)
        self.assertIn("llm_cmd='{model}' '-c' '{ctx}'", config)

    def test_tuned_arm_uses_frozen_context_for_cap(self):
        out, records = self.run_arm('tuned_large', cap=1536, extra=['--limit', '2'])
        self.assertEqual({r['context'] for r in records}, {512})
        self.assertEqual(self.ingest(out)['selections'], {LARGE + '@512': 2})

    def test_adaptive_arm_enables_scheduler_and_input_gate(self):
        out, records = self.run_arm('adaptive_input_gate', extra=['--limit', '1'])
        seen = json.loads((out / 'requests' / (self.heldout[0]['id'] + '-r1') / 'argv-seen.json').read_text())
        self.assertNotIn('--available-mb', seen)
        self.assertEqual(seen[seen.index('--ctx') + 1], '8192')
        self.assertEqual(seen[seen.index('--min-ctx') + 1], '512')  # 300 + 128 tokens fit 512
        self.assertEqual(records[0]['context'], 512)
        self.ingest(out)

    def test_adaptive_retry_after_oom_records_final_model(self):
        with mock.patch.dict(os.environ, {'FAKE_MODE': 'oom_large'}):
            out, records = self.run_arm('adaptive_input_gate', extra=['--limit', '1'])
        self.assertEqual((records[0]['status'], records[0]['model_id']), ('completed', SMALL))
        self.assertEqual(self.ingest(out)['selections'], {SMALL + '@512': 1})
        with mock.patch.dict(os.environ, {'FAKE_MODE': 'oom_large'}):
            out, records = self.run_arm(out='fixed', extra=['--limit', '1'])
        self.assertEqual((records[0]['status'], records[0]['model_id']), ('backend_failed', LARGE))

    def test_refusal_is_recorded_for_adaptive_and_rejected_for_fixed(self):
        with mock.patch.dict(os.environ, {'FAKE_MODE': 'refuse'}):
            out, records = self.run_arm('adaptive_input_gate', extra=['--limit', '1'])
            self.assertEqual(self.ingest(out)['selections'], {'refused': 1})
            with self.assertRaises(ValueError):
                self.run_arm(out='fixed', extra=['--limit', '1'])

    def test_ineligible_input_is_not_launched(self):
        m = json.loads(json.dumps(self.manifest))
        first = self.heldout[0]['id']
        for p in m['rendered_prompts']:
            if p['case_id'] == first:
                p['tokens'] = 1000  # 1000 + 128 > fixed_context 1024 but fits 2048
        bundle = self.freeze(m, 'tight')
        out, records = self.run_arm(extra=['--limit', '1'], bundle=bundle)
        self.assertEqual(records[0]['status'], 'context_ineligible')
        self.assertFalse((out / 'requests' / (first + '-r1')).exists())
        out, records = self.run_arm('adaptive_input_gate', out='adaptive', extra=['--limit', '1'], bundle=bundle)
        self.assertEqual(records[0]['context'], 2048)
        self.ingest(out, bundle)

    def test_refuses_mismatched_inputs(self):
        (self.dir / 'large.gguf').write_text('different weights')
        with self.assertRaises(ValueError):
            self.run_arm()
        (self.dir / 'large.gguf').write_text('fake large.gguf')
        self.run_arm(extra=['--limit', '1'])
        with self.assertRaises(ValueError):
            self.run_arm(extra=['--limit', '1'])  # output exists
        if platform.system() != 'Linux':
            with self.assertRaises(ValueError):
                self.run_arm(out='sd', extra=['--launcher', 'systemd'])

    def test_scope_launcher_works_from_request_directory_with_relative_output(self):
        cg = self.dir / 'cgroup'
        cg.mkdir()
        (cg / 'memory.max').write_text('1610612736\n')
        (cg / 'memory.events').write_text('oom_kill 0\n')
        (cg / 'memory.peak').write_text('1234567\n')
        run = self.dir / 'run'
        run.mkdir()
        (run / 'scope.sh').write_text(driver.SCOPE_SH)
        relative_run = Path(os.path.relpath(run))
        argv = driver.scope_argv(1536, relative_run, ['true'])
        wrapper = argv[argv.index('bash'):]
        subprocess.run(wrapper, cwd=run, check=True,
                       env=dict(os.environ, NANOCLAW_CGROUP_DIR=str(cg)))
        self.assertEqual(driver.cgroup_measurements(run), (1234567, 0))

    def test_scope_script_records_peak_and_oom_delta(self):
        cg = self.dir / 'cgroup'; cg.mkdir()
        (cg / 'memory.max').write_text('1610612736\n')
        (cg / 'memory.events').write_text('low 0\nhigh 0\nmax 3\noom 1\noom_kill 1\n')
        (cg / 'memory.peak').write_text('1500000000\n')
        run = self.dir / 'run'; run.mkdir()
        (run / 'scope.sh').write_text(driver.SCOPE_SH)
        bump = f"printf 'low 0\\nhigh 0\\nmax 9\\noom 2\\noom_kill 2\\n' > {cg}/memory.events; exit 137"
        p = subprocess.run(['bash', str(run / 'scope.sh'), str(run), 'sh', '-c', bump],
                           env=dict(os.environ, NANOCLAW_CGROUP_DIR=str(cg)))
        self.assertEqual(p.returncode, 137)
        self.assertEqual(driver.cgroup_measurements(run), (1500000000, 1))
        self.assertEqual(driver.cgroup_measurements(self.dir), (None, None))
        argv = driver.scope_argv(1536, run, ['x'])
        for prop in ('MemoryMax=1536M', 'MemorySwapMax=0', 'OOMPolicy=continue'):
            self.assertIn(prop, argv)


if __name__ == '__main__':
    unittest.main()
