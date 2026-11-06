import csv
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class RequestAccounting(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        zig = os.environ.get('ZIG') or shutil.which('zig')
        if not zig:
            raise RuntimeError('Set ZIG to a Zig 0.15.2 executable for integration tests')
        cls.build = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.build.name) / 'nanoclaw'
        command = [zig, 'build-exe', 'src/main.zig', '-femit-bin=' + str(cls.binary)]
        if sys.platform == 'darwin':
            command += ['-target', 'aarch64-macos.15.0']
        subprocess.run(command, cwd=ROOT, check=True)
        spec = importlib.util.spec_from_file_location('fake_models', ROOT / 'scripts/dev/make_test_models.py')
        cls.models = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.models)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def run_case(self, mode='retry', extra=(), prompt='hello', available='512'):
        with tempfile.TemporaryDirectory() as directory:
            d = Path(directory)
            for name in ('large', 'small'):
                (d / (name + '.gguf')).write_bytes(self.models.header('llama', 1, 64, 1, 1, 4096))
            backend = ROOT / 'tests/fixtures/accounting_backend.py'
            (d / 'nanoclaw-next.conf').write_text(
                f'llm_cmd="{sys.executable}" "{backend}" {mode} {{model}}\n'
                'model=large,large.gguf,3\nmodel=small,small.gguf,1\n'
                'memory_headroom_mb=0\nllm_timeout_ms=2000\n')
            result = subprocess.run([str(self.binary), 'bench', '--prompt', prompt, '--runs', '1',
                                     '--available-mb', available, *extra], cwd=d, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            sidecar = d / 'state/bench.csv.requests.jsonl'
            self.assertTrue(sidecar.exists(), 'bench must preserve request evidence, including failed attempts')
            record = json.loads(sidecar.read_text())
            with (d / 'state/bench.csv').open() as stream:
                row = next(csv.DictReader(stream))
            calibration = d / 'state/calibration.tsv'
            return record, row, calibration.exists()

    def test_retry_includes_failed_time_memory_and_raw_evidence(self):
        r, row, _ = self.run_case()
        self.assertEqual(r['schema_version'], 2)
        self.assertEqual(r['status'], 'completed')
        self.assertEqual(len(r['attempts']), 2)
        first, last = r['attempts']
        self.assertEqual(first['outcome'], 'signaled')
        self.assertEqual(first['signal'], 9)
        self.assertIn('failed output', first['stdout'])
        self.assertGreater(first['peak_rss_bytes'], last['peak_rss_bytes'])
        self.assertEqual(r['max_attempt_rss_bytes'], first['peak_rss_bytes'])
        self.assertGreaterEqual(r['total_wall_ms'], sum(a['wall_ms'] for a in r['attempts']))
        self.assertGreater(int(row['total_wall_ms']), int(row['wall_ms']))

    def test_deadline_is_not_reset_for_retry(self):
        r, _, _ = self.run_case('deadline', ['--deadline-ms', '150'])
        self.assertEqual(r['status'], 'deadline_exhausted')
        self.assertEqual(len(r['attempts']), 1)
        self.assertLess(r['total_wall_ms'], 600)
        self.assertTrue(r['deadline_missed'])
        self.assertEqual(r['attempts'][0]['signal'], 9)

    def test_nonzero_exit_retains_duration_and_stderr(self):
        r, row, _ = self.run_case('exit')
        self.assertEqual(r['status'], 'backend_error')
        self.assertEqual(r['attempts'][0]['exit_code'], 3)
        self.assertIn('bad flags', r['attempts'][0]['stderr'])
        self.assertGreater(int(row['total_wall_ms']), 0)

    def test_terminal_failure_retains_all_attempts(self):
        r, row, _ = self.run_case('fail')
        self.assertEqual(len(r['attempts']), 2)
        self.assertEqual(r['status'], 'backend_failed')
        self.assertGreaterEqual(r['total_wall_ms'], 120)
        self.assertEqual(row['attempts'], '2')

    def test_no_fit_is_scheduler_refusal(self):
        r, row, _ = self.run_case(available='0')
        self.assertEqual(r['status'], 'scheduler_refusal')
        self.assertEqual(r['attempts'], [])
        self.assertIsNone(r['max_attempt_rss_bytes'])
        self.assertEqual(row['peak_rss_mb'], '')

    def test_frozen_calibration_does_not_write(self):
        r, _, exists = self.run_case('ok', ['--freeze-calibration'])
        self.assertEqual(r['status'], 'completed')
        self.assertFalse(exists)

    def test_unread_stdin_cannot_evade_deadline(self):
        r, _, _ = self.run_case('blocked', ['--deadline-ms', '150'], prompt='x' * 100000)
        self.assertEqual(r['status'], 'deadline_exhausted')
        self.assertLess(r['total_wall_ms'], 600)

    def test_closed_output_cannot_evade_deadline(self):
        r, _, _ = self.run_case('closed', ['--deadline-ms', '150'])
        self.assertEqual(r['status'], 'deadline_exhausted')
        self.assertLess(r['total_wall_ms'], 600)

    def test_retry_uses_only_remaining_deadline(self):
        r, _, _ = self.run_case('retrydeadline', ['--deadline-ms', '400'])
        self.assertEqual(len(r['attempts']), 2)
        self.assertEqual(r['status'], 'deadline_exhausted')
        self.assertLess(r['attempts'][1]['wall_ms'], 350)
        self.assertLess(r['total_wall_ms'], 500)
