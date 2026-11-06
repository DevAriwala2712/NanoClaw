import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('quality', ROOT / 'scripts/evaluate_quality.py')
q = importlib.util.module_from_spec(SPEC)
if SPEC.loader and SPEC.origin and Path(SPEC.origin).exists():
    SPEC.loader.exec_module(q)

CASE = {'id': 'extract-01', 'family': 'extraction', 'scenario_group': 'disk', 'split': 'development',
        'prompt': 'Return free=12 from [e1] free=12.', 'evidence': {'e1': 'free=12'},
        'permitted_decisions': ['answer', 'refuse'], 'expects_refusal': False,
        'expected': [{'decision': 'answer', 'fields': {'free': 12}, 'evidence': ['e1']}]}
GOOD = json.dumps(CASE['expected'][0])

class QualityScoring(unittest.TestCase):
    def test_exact_fields_and_evidence(self):
        self.assertEqual(q.score_response(CASE, GOOD)['outcome'], 'correct')
        wrong = copy.deepcopy(CASE['expected'][0]); wrong['fields']['free'] = 13
        self.assertEqual(q.score_response(CASE, json.dumps(wrong))['outcome'], 'incorrect')
        wrong['fields']['free'] = 12; wrong['evidence'] = ['invented']
        self.assertEqual(q.score_response(CASE, json.dumps(wrong))['outcome'], 'incorrect')

    def test_malformed_and_extra_text_are_invalid(self):
        for raw in ('```json\n' + GOOD + '\n```', GOOD + ' extra', 'null', '{}',
                    '{"decision":"answer","decision":"refuse","fields":{},"evidence":[]}',
                    '{"decision":"answer","fields":{"free":NaN},"evidence":["e1"]}'):
            with self.subTest(raw=raw):
                self.assertTrue(q.score_response(CASE, raw)['invalid_output'])

    def test_forbidden_decision_is_counted_even_with_bad_shape(self):
        s = q.score_response(CASE, '{"decision":"delete_all","extra":42}')
        self.assertTrue(s['forbidden_selection'])
        self.assertTrue(s['invalid_output'])

    def test_boolean_is_not_an_integer_answer(self):
        c = copy.deepcopy(CASE); c['expected'][0]['fields']['free'] = 1
        raw = json.dumps({'decision':'answer','fields':{'free':True},'evidence':['e1']})
        self.assertEqual(q.score_response(c, raw)['outcome'], 'incorrect')

    def test_correct_and_unnecessary_refusals(self):
        refusal = {'decision':'refuse','fields':{},'evidence':['e1']}
        self.assertEqual(q.score_response(CASE,json.dumps(refusal))['outcome'],'unnecessary_refusal')
        c = copy.deepcopy(CASE); c['expects_refusal'] = True; c['expected'] = [refusal]
        self.assertEqual(q.score_response(c,json.dumps(refusal))['outcome'],'correct_refusal')

    def test_missing_failure_and_duplicate_records(self):
        r = {'case_id':CASE['id'],'repetition':1,'status':'backend_failed','response':None,
             'total_wall_ms':240,'max_attempt_rss_bytes':123,'cgroup_peak_bytes':None,
             'deadline_missed':False,'oom_kills':1}
        summary = q.summarize([CASE],[r])
        self.assertEqual(summary['correct_supported_tasks'],0)
        self.assertEqual(summary['supported_tasks'],1)
        self.assertEqual(summary['failure_latency_ms']['p50'],240)
        self.assertEqual(summary['oom_kills'],1)
        self.assertEqual(q.summarize([CASE],[])['outcomes']['missing'],1)
        with self.assertRaises(ValueError): q.summarize([CASE],[r,r])
        self.assertFalse(summary['quality_floor_passed'])

    def test_repetitions_do_not_become_independent_cases(self):
        records = [{'case_id':CASE['id'],'repetition':i,'status':'completed','response':GOOD,
                    'total_wall_ms':12,'max_attempt_rss_bytes':3,'cgroup_peak_bytes':4,
                    'deadline_missed':False,'oom_kills':0} for i in (1,2)]
        s = q.summarize([CASE],records,repetitions=2)
        self.assertEqual(s['supported_tasks'],1)
        self.assertEqual(s['correct_supported_tasks'],1)
        records[1]['response'] = '{}'
        self.assertEqual(q.summarize([CASE],records,repetitions=2)['correct_supported_tasks'],0)

    def test_token_eligibility_includes_reserved_output(self):
        self.assertTrue(q.eligible(384,512))
        self.assertFalse(q.eligible(385,512))
        with self.assertRaises(ValueError): q.eligible(True,512)
        with self.assertRaises(ValueError): q.eligible(-1,512)

    def test_suite_balance_evidence_and_no_split_leakage(self):
        cases = q.load_cases(ROOT / 'evaluation/cases.jsonl')
        self.assertEqual(len(cases),60)
        for family in ('extraction','diagnosis','uncertainty'):
            for split in ('development','heldout'):
                self.assertEqual(sum(c['family']==family and c['split']==split for c in cases),10)
        bad = copy.deepcopy(cases)
        bad[-1]['scenario_group'] = bad[0]['scenario_group']
        with self.assertRaises(ValueError): q.validate_cases(bad)
        bad = copy.deepcopy(cases); bad[0]['evidence']['e1'] = 'not in prompt'
        with self.assertRaises(ValueError): q.validate_cases(bad)

    def test_template_cannot_be_frozen_as_ready(self):
        cases = q.load_cases(ROOT / 'evaluation/cases.jsonl')
        manifest = json.loads((ROOT/'evaluation/manifest.template.json').read_text())
        q.validate_manifest(manifest,cases)
        with self.assertRaises(ValueError): q.validate_manifest(manifest,cases,ready=True)

    def test_fixture_expected_responses_are_scorable(self):
        for c in q.load_cases(ROOT / 'evaluation/cases.jsonl'):
            for expected in c['expected']:
                score = q.score_response(c,json.dumps(expected))
                self.assertEqual(score['outcome'],'correct_refusal' if c['expects_refusal'] else 'correct',c['id'])

    def test_unknown_measurements_and_unbound_scores_stay_provisional(self):
        r = {'case_id':CASE['id'],'repetition':1,'status':'completed','response':GOOD,
             'total_wall_ms':None,'max_attempt_rss_bytes':None,'cgroup_peak_bytes':None,
             'deadline_missed':None,'oom_kills':None}
        s=q.summarize([CASE],[r])
        self.assertIsNone(s['oom_kills'])
        self.assertIsNone(s['deadline_misses'])
        self.assertTrue(s['provisional'])

    def test_diagnosis_answer_positions_are_balanced(self):
        cases=q.load_cases(ROOT/'evaluation/cases.jsonl')
        for split in ('development','heldout'):
            selected=[c for c in cases if c['family']=='diagnosis' and c['split']==split]
            self.assertEqual(sum(c['permitted_decisions'][0]==c['expected'][0]['decision'] for c in selected),5)
