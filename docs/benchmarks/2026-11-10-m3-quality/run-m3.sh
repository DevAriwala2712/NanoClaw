#!/usr/bin/env bash
# Run from the archived source root on nanoclaw-m2, with frozen inputs in place.
set -euo pipefail

root=$PWD
backend=/home/ubuntu/llama-b11669
models=/home/ubuntu/NanoClaw/models
model_flags=(
  --model "smollm2-1.7b-q4=$models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf"
  --model "smollm2-360m-q4=$models/SmolLM2-360M-Instruct-Q4_K_M.gguf"
)

run_arm() {
  local bundle=$1 policy=$2 cap=$3 out=$4
  shift 4
  if [[ ! -e "$out/run.json" ]]; then
    python3 scripts/run_quality_arm.py --bundle "$bundle" --policy "$policy" \
      --cap-mib "$cap" "${model_flags[@]}" --calibration "$root/calibration.tsv" \
      --nanoclaw "$root/nanoclaw-next" --out "$out" --deadline-ms 120000 --drop-caches "$@"
  fi
  if [[ ! -e "$out/summary.json" ]]; then
    python3 "$bundle/evaluate_quality.py" ingest --bundle "$bundle" \
      --run "$out/run.json" --records "$out/records.jsonl" --out "$out/summary.json"
  fi
}

case ${1:?choose smoke, development, prepare-heldout, or heldout} in
  smoke)
    for policy in fixed_small adaptive_input_gate; do
      run_arm bundles/smoke "$policy" 1536 "runs/smoke/$policy" --limit 2
    done
    ;;
  development)
    for cap in 1536 2048 3072; do
      for ctx in 512 1024 2048 4096 8192; do
        run_arm "bundles/development-$ctx" tuned_large "$cap" "runs/development/$cap-$ctx"
      done
    done
    if [[ ! -e tuned.json ]]; then
      python3 scripts/prepare_quality_manifest.py choose-tuned runs/development/*/summary.json --out tuned.json
    fi
    ;;
  prepare-heldout)
    if [[ ! -e manifests/heldout.json ]]; then
      hardware=$(python3 -c 'import json; print(json.load(open("manifests/development-8192.json"))["hardware"])')
      authorization=$(python3 -c 'import json; print(json.load(open("manifests/development-8192.json"))["authorization"])')
      ordering=$(python3 -c 'import json; print(json.load(open("manifests/development-8192.json"))["ordering"])')
      python3 scripts/prepare_quality_manifest.py prepare --split heldout --tuned-selection tuned.json \
        "${model_flags[@]}" --calibration "$root/calibration.tsv" --tokenizer "$backend/llama-tokenize" \
        --llama-completion "$backend/llama-completion" --source-commit "$(cat source-commit)" \
        --hardware "$hardware" --authorization "$authorization" --ordering "$ordering" \
        --repetitions 1 --out manifests/heldout.json
    fi
    if [[ ! -d bundles/heldout ]]; then
      python3 scripts/evaluate_quality.py freeze --manifest manifests/heldout.json --out bundles/heldout
    fi
    ;;
  heldout)
    for cap in 1536 2048 3072; do
      for policy in fixed_large fixed_small tuned_large adaptive_input_gate; do
        run_arm bundles/heldout "$policy" "$cap" "runs/heldout/$cap-$policy"
      done
    done
    ;;
  *) exit 2 ;;
esac
