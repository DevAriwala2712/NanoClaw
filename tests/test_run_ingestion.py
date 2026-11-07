import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('quality', ROOT / 'scripts/evaluate_quality.py')
q = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(q)

CASES_PATH = ROOT / 'evaluation/cases.jsonl'
LARGE, SMALL = 'smollm2-1.7b-q4', 'smollm2-360m-q4'
ARGS = {LARGE: ['-ngl', '0', '-t', '4'], SMALL: ['-ngl', '0', '-t', '4', '--small']}


def render(case, model):
    return '<|im_start|>user\n' + case['prompt'] + '<|im_end|>\n' + model


def ready_manifest(cases):
    m = json.loads((ROOT / 'evaluation/manifest.template.json').read_text())
    m.update(split='heldout', repetitions=1, fixed_context=1024, hardware='test vm',
             backend_build='llama.cpp b0', source_commit='0' * 40, sampling='temp 0 seed 1',
             threads=4, cache_procedure='drop caches', ordering='alternating', authorization='unit test',
             cases_sha256=q.digest(CASES_PATH), development_results_sha256='1' * 64,
             tuned_context_by_cap={'1536': 512, '2048': 1024, '3072': 2048})
    for model in m['models']:
        model.update(sha256='2' * 64, tokenizer_id='smollm2', template_sha256='3' * 64,
                     calibration_sha256='4' * 64, backend_arguments=ARGS[model['id']])
    m['rendered_prompts'] = [{'case_id': c['id'], 'model_id': mid, 'text': render(c, mid),
                              'tokens': 300, 'token_count_source': 'llama-tokenize b0'}
                             for c in cases if c['split'] == 'heldout' for mid in (LARGE, SMALL)]
    return m


def record(case, model=LARGE, context=1024, **overrides):
    r = {'case_id': case['id'], 'repetition': 1, 'status': 'completed',
         'response': json.dumps(case['expected'][0]), 'total_wall_ms': 900,
         'max_attempt_rss_bytes': 10 ** 9, 'cgroup_peak_bytes': 11 * 10 ** 8, 'oom_kills': 0,
         'deadline_missed': False, 'model_id': model, 'context': context, 'prompt_tokens': 300,
         'rendered_prompt_sha256': hashlib.sha256(render(case, model).encode()).hexdigest(),
         'backend_arguments': ARGS[model]}
    r.update(overrides)
    return r


class RunIngestion(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.cases = q.load_cases(CASES_PATH)
        self.heldout = [c for c in self.cases if c['split'] == 'heldout']
        self.manifest = ready_manifest(self.cases)
        self.bundle = self.freeze(self.manifest)

    def tearDown(self):
        self.tmp.cleanup()

    def freeze(self, manifest, name='bundle'):
        path = self.dir / (name + '.json')
        path.write_text(json.dumps(manifest))
        q.freeze_bundle(CASES_PATH, path, self.dir / name)
        return self.dir / name

    def ingest(self, records, policy='fixed_large', cap=2048, **run_overrides):
        rec = self.dir / 'records.jsonl'
        rec.write_text(''.join(json.dumps(r) + '\n' for r in records))
        run = {'schema_version': 1, 'policy': policy, 'cap_mib': cap, 'split': 'heldout', 'repetitions': 1,
               'bundle_checksums_sha256': q.digest(self.bundle / 'checksums.json'),
               'records_sha256': q.digest(rec)}
        run.update(run_overrides)
        (self.dir / 'run.json').write_text(json.dumps(run))
        return q.ingest(self.bundle, self.dir / 'run.json', rec)

    def test_bound_complete_measured_run_can_pass_the_gate(self):
        s = self.ingest([record(c) for c in self.heldout])
        self.assertTrue(s['bound'])
        self.assertFalse(s['provisional'])
        self.assertTrue(s['quality_floor_passed'])
        self.assertEqual(s['selections'], {LARGE + '@1024': 30})

    def test_missing_cgroup_charge_keeps_result_provisional(self):
        records = [record(c) for c in self.heldout]
        records[0]['cgroup_peak_bytes'] = None
        s = self.ingest(records)
        self.assertTrue(s['observed_quality_floor_met'])
        self.assertTrue(s['provisional'])
        self.assertFalse(s['quality_floor_passed'])
        self.assertIn('cgroup_peak_bytes', s['provisional_reason'])

    def test_missing_rows_keep_result_provisional(self):
        s = self.ingest([record(c) for c in self.heldout[1:]])
        self.assertTrue(s['provisional'])
        self.assertFalse(s['quality_floor_passed'])

    def test_arm_must_use_its_frozen_model_and_context(self):
        c = self.heldout[0]
        for policy, bad in (('fixed_large', record(c, model=SMALL)),
                            ('fixed_small', record(c)),
                            ('fixed_large', record(c, context=2048)),
                            ('tuned_large', record(c, context=1024))):
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                self.ingest([bad], policy=policy, cap=1536)
        s = self.ingest([record(c, context=512)], policy='tuned_large', cap=1536)
        self.assertEqual(s['selections'], {LARGE + '@512': 1})

    def test_adaptive_may_pick_either_model_or_refuse(self):
        a, b, c = self.heldout[:3]
        refusal = record(c, status='scheduler_refusal', response=None, model_id=None, context=None)
        s = self.ingest([record(a, model=SMALL, context=512), record(b, context=4096), refusal],
                        policy='adaptive_input_gate')
        self.assertEqual(s['selections'], {SMALL + '@512': 1, LARGE + '@4096': 1, 'refused': 1})
        with self.assertRaises(ValueError):
            self.ingest([refusal], policy='fixed_large')

    def test_prompt_tokens_arguments_and_rendering_must_match(self):
        c = self.heldout[0]
        for bad in (record(c, prompt_tokens=299), record(c, rendered_prompt_sha256='0' * 64),
                    record(c, backend_arguments=['-ngl', '99'])):
            with self.assertRaises(ValueError):
                self.ingest([bad])

    def test_eligibility_status_must_agree_with_token_counts(self):
        m = copy.deepcopy(self.manifest)
        m['rendered_prompts'][0]['tokens'] = 1000  # 1000 + 128 > fixed_context 1024
        self.bundle = self.freeze(m, 'tight')
        c = next(x for x in self.heldout if x['id'] == m['rendered_prompts'][0]['case_id'])
        with self.assertRaises(ValueError):
            self.ingest([record(c, prompt_tokens=1000)])
        s = self.ingest([record(c, prompt_tokens=1000, status='context_ineligible', response=None)])
        self.assertEqual(s['outcomes']['context_ineligible'], 1)
        with self.assertRaises(ValueError):
            self.ingest([record(self.heldout[1], status='context_ineligible', response=None)])
        unlaunched = record(c, prompt_tokens=1000, status='context_ineligible', response=None,
                            **{k: None for k in q.MEASUREMENTS})
        s = self.ingest([unlaunched] + [record(x) for x in self.heldout if x['id'] != c['id']])
        self.assertFalse(s['provisional'], 'an unlaunched request has nothing to measure')

    def test_tampered_bundle_and_records_are_rejected(self):
        records = [record(c) for c in self.heldout]
        with self.assertRaises(ValueError):
            self.ingest(records, records_sha256='0' * 64)
        with self.assertRaises(ValueError):
            self.ingest(records, bundle_checksums_sha256='0' * 64)
        with self.assertRaises(ValueError):
            self.ingest(records, cap=4096)
        manifest = self.bundle / 'manifest.json'
        manifest.write_text(manifest.read_text().replace('"threads": 4', '"threads": 8'))
        with self.assertRaises(ValueError):
            self.ingest(records)


if __name__ == '__main__':
    unittest.main()
