#!/usr/bin/env bash
# Paired feasibility probe. Run from the VM study root after the M3 held-out study.
set -euo pipefail

mkdir -p runs/kv
python3 - <<'PY'
import json
from pathlib import Path

for cache in ('f16', 'q8_0'):
    m = json.loads(Path('manifests/smoke.json').read_text())
    m['ordering'] = 'KV feasibility probe: f16 then q8_0, each with the two smoke cases in order'
    for model in m['models']:
        model['backend_arguments'] += ['--flash-attn', 'on', '--cache-type-k', cache, '--cache-type-v', cache]
    out = Path(f'manifests/kv-{cache}.json')
    if not out.exists():
        out.write_text(json.dumps(m, indent=2) + '\n')
PY

for cache in f16 q8_0; do
  bundle="bundles/kv-$cache"
  out="runs/kv/$cache"
  if [[ ! -d "$bundle" ]]; then
    python3 scripts/evaluate_quality.py freeze --manifest "manifests/kv-$cache.json" \
      --cases manifests/smoke-cases.jsonl --out "$bundle"
  fi
  if [[ ! -f "$out/run.json" ]]; then
    python3 scripts/run_quality_arm.py --bundle "$bundle" --policy fixed_large --cap-mib 3072 \
      --model "smollm2-1.7b-q4=$HOME/NanoClaw/models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf" \
      --calibration "$PWD/calibration.tsv" --nanoclaw "$PWD/nanoclaw-next" \
      --out "$out" --drop-caches --deadline-ms 120000 --limit 2
  fi
  if [[ ! -f "$out/summary.json" ]]; then
    python3 "$bundle/evaluate_quality.py" ingest --bundle "$bundle" \
      --run "$out/run.json" --records "$out/records.jsonl" --out "$out/summary.json"
  fi
done
