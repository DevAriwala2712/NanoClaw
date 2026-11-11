#!/usr/bin/env python3
"""Tabulate manifest-bound arm results from one evidence directory."""

from argparse import ArgumentParser
import csv
import json
import math
from pathlib import Path
import sys


def quantile(values, fraction):
    return values[max(0, math.ceil(fraction * len(values)) - 1)] if values else None


def mib(value):
    return round(value / 1024**2, 1) if value is not None else None


def load_arm(folder):
    records = [json.loads(line) for line in (folder / 'records.jsonl').read_text().splitlines()]
    summary = json.loads((folder / 'summary.json').read_text())
    launched = [row for row in records if row['status'] != 'context_ineligible']
    if not summary['bound'] or summary['provisional'] or len(records) != summary['task_count']:
        raise ValueError(f'{folder}: expected a bound, complete, measured single-repetition arm')
    all_latencies = sorted(row['total_wall_ms'] for row in launched)
    outcome = summary['outcomes']
    selections = summary['selections']
    families = summary['family_correct']
    return {
        'cap_mib': summary['cap_mib'],
        'arm': folder.name.split('-', 1)[1],
        'tasks': len(records),
        'correct_supported': summary['correct_supported_tasks'],
        'supported_tasks': summary['supported_tasks'],
        'correct_refusals': summary['correct_refusal_tasks'],
        'refusal_tasks': summary['refusal_tasks'],
        'extraction_correct': families.get('extraction', 0),
        'diagnosis_correct': families.get('diagnosis', 0),
        'uncertainty_correct': families.get('uncertainty', 0),
        'invalid_outputs': summary['invalid_outputs'],
        'forbidden_selections': summary['forbidden_selections'],
        'backend_completions': sum(row['status'] == 'completed' for row in launched),
        'context_ineligible': outcome.get('context_ineligible', 0),
        'scheduler_refusals': outcome.get('scheduler_refusal', 0),
        'backend_failures': sum(row['status'] in ('backend_failed', 'backend_error', 'deadline_exhausted')
                                for row in launched),
        'oom_kills': sum(row['oom_kills'] for row in launched),
        'deadline_misses': sum(row['deadline_missed'] for row in launched),
        'all_requests_p50_ms': quantile(all_latencies, 0.5),
        'all_requests_p95_ms': quantile(all_latencies, 0.95),
        'completed_p50_ms': summary['completion_latency_ms']['p50'],
        'completed_p95_ms': summary['completion_latency_ms']['p95'],
        'failed_p50_ms': summary['failure_latency_ms']['p50'],
        'failed_p95_ms': summary['failure_latency_ms']['p95'],
        'max_attempt_rss_mib': mib(summary['max_attempt_rss_bytes']),
        'max_cgroup_mib': mib(summary['max_cgroup_peak_bytes']),
        'quality_floor_passed': summary['quality_floor_passed'],
        'selections': json.dumps(selections, sort_keys=True, separators=(',', ':')),
    }


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument('stage', type=Path, help='Directory containing one subdirectory per arm')
    parser.add_argument('--expected-arms', type=int, required=True)
    args = parser.parse_args()
    rows = [load_arm(folder) for folder in sorted(args.stage.iterdir()) if folder.is_dir()]
    if len(rows) != args.expected_arms:
        raise ValueError(f'expected {args.expected_arms} arms, found {len(rows)}')
    if args.stage.name == 'development':
        rows.sort(key=lambda row: (row['cap_mib'], int(row['arm'])))
    writer = csv.DictWriter(sys.stdout, fieldnames=list(rows[0]), lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)


if __name__ == '__main__':
    main()
