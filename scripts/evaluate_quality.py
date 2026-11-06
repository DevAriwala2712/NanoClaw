#!/usr/bin/env python3
"""Offline quality evaluation. Never invokes inference, a VM, or network access."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import shutil

FAMILIES = ('extraction', 'diagnosis', 'uncertainty')
STATUSES = {'completed', 'backend_failed', 'backend_error', 'scheduler_refusal',
            'deadline_exhausted', 'context_ineligible'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strict_json(text):
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, 'duplicate JSON key: ' + key)
            out[key] = value
        return out
    def constant(value):
        raise ValueError('non-finite JSON number: ' + value)
    return json.loads(text, object_pairs_hook=pairs, parse_constant=constant)


def read_jsonl(path):
    return [strict_json(line) for line in Path(path).read_text().splitlines() if line.strip()]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)


def response_shape(value):
    return (isinstance(value, dict) and set(value) == {'decision', 'fields', 'evidence'}
            and isinstance(value['decision'], str) and isinstance(value['fields'], dict)
            and isinstance(value['evidence'], list)
            and all(isinstance(e, str) for e in value['evidence'])
            and len(value['evidence']) == len(set(value['evidence'])))


def score_response(case, raw):
    score = {'outcome': 'invalid', 'invalid_output': True, 'forbidden_selection': False}
    try:
        value = strict_json(raw)
    except (ValueError, TypeError):
        return score
    if isinstance(value, dict) and isinstance(value.get('decision'), str):
        score['forbidden_selection'] = value['decision'] not in case['permitted_decisions']
    if not response_shape(value):
        return score
    score['invalid_output'] = False
    value['evidence'] = sorted(value['evidence'])
    accepted = [dict(e, evidence=sorted(e['evidence'])) for e in case['expected']]
    if score['forbidden_selection']:
        score['outcome'] = 'forbidden_selection'
    elif canonical(value) in [canonical(e) for e in accepted]:
        score['outcome'] = 'correct_refusal' if case['expects_refusal'] else 'correct'
    elif value['decision'] == 'refuse' and not case['expects_refusal']:
        score['outcome'] = 'unnecessary_refusal'
    else:
        score['outcome'] = 'incorrect'
    return score


def validate_cases(cases):
    require(len(cases) == 60, 'pilot requires exactly 60 cases')
    ids, groups, prompts = set(), {}, set()
    required = {'schema_version','id','family','scenario_group','split','prompt','evidence',
                'permitted_decisions','expects_refusal','expected'}
    for c in cases:
        require(set(c) == required and c['schema_version'] == 1, 'invalid case schema')
        for key in ('id','scenario_group','prompt'):
            require(isinstance(c[key],str) and c[key], 'empty case ' + key)
        require(c['id'] not in ids and c['prompt'] not in prompts, 'duplicate case or prompt')
        ids.add(c['id']); prompts.add(c['prompt'])
        require(c['family'] in FAMILIES and c['split'] in ('development','heldout'), 'bad family/split')
        old = groups.setdefault(c['scenario_group'], c['split'])
        require(old == c['split'], 'scenario group leaks across split')
        require(type(c['expects_refusal']) is bool, 'refusal label must be boolean')
        require(isinstance(c['evidence'],dict) and c['evidence'], 'missing evidence')
        require(all(isinstance(k,str) and isinstance(v,str) and v and v in c['prompt']
                    for k,v in c['evidence'].items()), 'evidence span absent from prompt')
        require(isinstance(c['permitted_decisions'],list) and c['permitted_decisions']
                and all(isinstance(v,str) for v in c['permitted_decisions']), 'invalid permitted decisions')
        require(isinstance(c['expected'],list) and c['expected'], 'missing labels')
        for e in c['expected']:
            require(response_shape(e), 'invalid expected response')
            require(e['decision'] in c['permitted_decisions'], 'forbidden label')
            require((e['decision'] == 'refuse') == c['expects_refusal'], 'inconsistent refusal label')
            require(set(e['evidence']) <= set(c['evidence']), 'unknown labeled evidence')
    counts = Counter((c['family'], c['split']) for c in cases)
    require(all(counts[f,s] == 10 for f in FAMILIES for s in ('development','heldout')), 'unbalanced suite')


def load_cases(path):
    cases = read_jsonl(path)
    validate_cases(cases)
    return cases


def eligible(prompt_tokens, context, output_tokens=128):
    require(all(type(n) is int and n >= 0 for n in (prompt_tokens,context,output_tokens)), 'invalid token count')
    return prompt_tokens + output_tokens <= context


def percentiles(values):
    values = sorted(values)
    return {name: values[max(0, math.ceil(len(values)*p)-1)] if values else None
            for name,p in (('p50',.5),('p95',.95))}


def summarize(cases, records, repetitions=1):
    require(type(repetitions) is int and repetitions > 0, 'invalid repetition count')
    by_id = {c['id']:c for c in cases}
    indexed = {}
    for r in records:
        require(r.get('case_id') in by_id, 'unknown case ID')
        require(type(r.get('repetition')) is int and 1 <= r['repetition'] <= repetitions, 'invalid repetition')
        key = r['case_id'], r['repetition']
        require(key not in indexed, 'duplicate case/repetition')
        require(r.get('status') in STATUSES, 'unknown status')
        for metric in ('total_wall_ms','max_attempt_rss_bytes','cgroup_peak_bytes','oom_kills'):
            require(metric in r and (r[metric] is None or (type(r[metric]) is int and r[metric] >= 0)), 'bad/missing metric ' + metric)
        require(type(r.get('deadline_missed')) is bool or r.get('deadline_missed') is None, 'bad deadline flag')
        require(r['status'] != 'completed' or isinstance(r.get('response'),str), 'completed response must be text')
        indexed[key] = r
    counts = Counter()
    correct_cases, family_correct = set(), Counter()
    invalid = forbidden = oom = deadline = 0
    latencies, failed_latencies, rss, charges = [], [], [], []
    details = []
    for c in cases:
        all_correct = True
        for rep in range(1,repetitions+1):
            r = indexed.get((c['id'],rep))
            if r is None:
                score = {'outcome':'missing','invalid_output':False,'forbidden_selection':False}
            elif r['status'] == 'completed':
                score = score_response(c,r['response'])
            else:
                score = {'outcome':r['status'],'invalid_output':False,'forbidden_selection':False}
            counts[score['outcome']] += 1
            invalid += score['invalid_output']; forbidden += score['forbidden_selection']
            all_correct &= score['outcome'] in ('correct','correct_refusal')
            details.append(dict(case_id=c['id'],repetition=rep,**score))
            if r:
                oom += r['oom_kills'] or 0
                deadline += bool(r.get('deadline_missed'))
                if r['total_wall_ms'] is not None:
                    (latencies if r['status']=='completed' else failed_latencies).append(r['total_wall_ms'])
                if r['max_attempt_rss_bytes'] is not None: rss.append(r['max_attempt_rss_bytes'])
                if r['cgroup_peak_bytes'] is not None: charges.append(r['cgroup_peak_bytes'])
        if all_correct:
            correct_cases.add(c['id']); family_correct[c['family']] += 1
    family_totals = Counter(c['family'] for c in cases)
    supported = [c for c in cases if not c['expects_refusal']]
    refused = [c for c in cases if c['expects_refusal']]
    complete_heldout = len(cases)==30 and all(c['split']=='heldout' for c in cases) and all(family_totals[f]==10 for f in FAMILIES)
    return {'schema_version':1,'task_count':len(cases),'repetitions':repetitions,
            'supported_tasks':len(supported),'correct_supported_tasks':sum(c['id'] in correct_cases for c in supported),
            'refusal_tasks':len(refused),'correct_refusal_tasks':sum(c['id'] in correct_cases for c in refused),
            'family_correct':dict(family_correct),'outcomes':dict(counts), 'invalid_outputs':invalid,
            'forbidden_selections':forbidden,
            'oom_kills':oom if len(indexed)==len(cases)*repetitions and all(r['oom_kills'] is not None for r in records) else None,
            'deadline_misses':deadline if len(indexed)==len(cases)*repetitions and all(r.get('deadline_missed') is not None for r in records) else None,
            'provisional':True,
            'provisional_reason':'Offline response scoring is not bound to an executed manifest or verified tokenizer counts.',
            'unknown_oom_measurements':sum(r['oom_kills'] is None for r in records),
            'completion_latency_ms':percentiles(latencies),'failure_latency_ms':percentiles(failed_latencies),
            'max_attempt_rss_bytes':max(rss,default=None),'max_cgroup_peak_bytes':max(charges,default=None),
            'observed_quality_floor_met':bool(complete_heldout and not forbidden and all(family_correct[f]>=9 for f in FAMILIES)),
            'quality_floor_passed':False,'details':details}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def validate_manifest(m, cases, ready=False):
    require(m.get('schema_version')==1, 'unsupported manifest schema')
    require(m.get('contexts')==[512,1024,2048,4096] and m.get('output_tokens')==128, 'changed study budgets')
    require(m.get('calibration_frozen') is True, 'evaluation must freeze calibration')
    require(m.get('split') in ('development','heldout'), 'choose one split')
    require(m.get('policies') == ['fixed_large','fixed_small','tuned_large','adaptive_input_gate'], 'unexpected policy arms')
    require(m.get('caps_mib') and all(type(v) is int and v>0 for v in m['caps_mib']), 'invalid caps')
    if not ready: return
    for field in ('hardware','backend_build','source_commit','sampling','threads','cache_procedure','ordering','authorization'):
        require(m.get(field), 'unresolved manifest field: '+field)
    require(m.get('process_lifetime')=='cold' and m.get('swap_enabled') is False, 'cold/no-swap study required')
    require(type(m.get('repetitions')) is int and m['repetitions']>0, 'set repetitions')
    require(m.get('cases_sha256') and len(m['cases_sha256'])==64, 'missing cases hash')
    require(len(m.get('models',[]))==2, 'two model identities required')
    model_ids = set()
    for model in m['models']:
        require(model.get('id') not in model_ids and model.get('id'), 'duplicate/missing model ID')
        model_ids.add(model['id'])
        for field in ('sha256','tokenizer_id','template_sha256','calibration_sha256','backend_arguments'):
            require(model.get(field), 'unresolved model field: '+field)
    expected = {(c['id'],mid) for c in cases if c['split']==m['split'] for mid in model_ids}
    seen = set()
    for p in m.get('rendered_prompts',[]):
        key = p.get('case_id'),p.get('model_id')
        require(key in expected and key not in seen, 'duplicate/unknown rendered prompt')
        require(isinstance(p.get('text'),str) and p['text'], 'missing rendered prompt')
        case = next(c for c in cases if c['id']==p['case_id'])
        require(case['prompt'] in p['text'], 'rendered prompt dropped input')
        require(type(p.get('tokens')) is int and p['tokens']>0, 'missing tokenizer count')
        require(p.get('token_count_source'), 'missing token count provenance')
        seen.add(key)
    require(seen==expected, 'need per-model rendered prompt counts for every case')
    require(set(m.get('tuned_context_by_cap',{}))=={str(v) for v in m['caps_mib']}, 'freeze tuned baseline per cap')
    require(all(v in m['contexts'] for v in m['tuned_context_by_cap'].values()), 'invalid tuned context')
    if m['split']=='heldout': require(m.get('development_results_sha256'), 'held-out baseline needs development provenance')


def freeze_bundle(cases_path, manifest_path, destination):
    cases = load_cases(cases_path)
    m = strict_json(Path(manifest_path).read_text())
    validate_manifest(m,cases,ready=True)
    require(m['cases_sha256']==digest(cases_path), 'cases changed since manifest preparation')
    destination = Path(destination)
    require(not destination.exists(), 'refusing to overwrite an evidence bundle')
    destination.mkdir(parents=True)
    shutil.copyfile(cases_path,destination/'cases.jsonl')
    (destination/'manifest.json').write_text(json.dumps(m,indent=2)+'\n')
    shutil.copyfile(__file__,destination/'evaluate_quality.py')
    hashes = {p.name:digest(p) for p in destination.iterdir()}
    (destination/'checksums.json').write_text(json.dumps(hashes,indent=2)+'\n')
    return hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['validate','score','freeze'])
    parser.add_argument('--cases',type=Path,default=Path('evaluation/cases.jsonl'))
    parser.add_argument('--manifest',type=Path,default=Path('evaluation/manifest.template.json'))
    parser.add_argument('--records',type=Path)
    parser.add_argument('--out',type=Path)
    parser.add_argument('--split',choices=['development','heldout'],default='heldout')
    parser.add_argument('--repetitions',type=int,default=1)
    args = parser.parse_args()
    try:
        cases = load_cases(args.cases)
        if args.command=='validate':
            validate_manifest(strict_json(args.manifest.read_text()),cases)
            result = {'cases':len(cases),'cases_sha256':digest(args.cases),'experiment_ready':False}
        elif args.command=='freeze':
            require(args.out is not None,'--out directory required')
            result = freeze_bundle(args.cases,args.manifest,args.out)
        else:
            require(args.records is not None,'--records required')
            result = summarize([c for c in cases if c['split']==args.split],read_jsonl(args.records),args.repetitions)
        text = json.dumps(result,indent=2,allow_nan=False)+'\n'
        if args.out and args.command!='freeze':
            with args.out.open('x') as stream: stream.write(text)
        else: print(text,end='')
    except (ValueError,OSError) as err:
        parser.exit(2,str(err)+'\n')

if __name__=='__main__': main()
