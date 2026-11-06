"""Small deterministic process fixture; no inference or model loading."""
import os
import signal
import sys
import time

mode, model = sys.argv[1:3]
if mode == 'blocked':
    time.sleep(10)
if mode == 'closed':
    os.close(1)
    os.close(2)
    time.sleep(10)
sys.stdin.read()
if mode == 'exit':
    print('bad flags', file=sys.stderr, flush=True)
    sys.exit(3)
if mode in ('retry', 'retrydeadline') and 'large' in model:
    data = bytearray(24 * 1024 * 1024)
    print('failed output', flush=True)
    time.sleep(0.12)
    os.kill(os.getpid(), signal.SIGKILL)
if mode == 'fail':
    time.sleep(0.06)
    os.kill(os.getpid(), signal.SIGKILL)
if mode in ('deadline', 'retrydeadline'):
    time.sleep(5)
print('answer', flush=True)
