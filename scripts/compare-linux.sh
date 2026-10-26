#!/usr/bin/env bash
# Same prompt, same device, same memory cap: fixed llama.cpp vs NanoClaw-Next.
#
# STATUS: written against llama.cpp's CLI and systemd-run; not yet executed on
# real hardware (docs/PLAN.md M2). Expect to adjust flags for your llama.cpp build.
#
# Usage:
#   scripts/compare-linux.sh MEM_CAP BIG_MODEL.gguf PROMPT [RUNS]
#   e.g. scripts/compare-linux.sh 1536M models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf "Explain swap" 10
#
# Needs: Linux with cgroup v2 + systemd (user scopes), llama-completion (or set LLAMA_BIN),
# nanoclaw-next on PATH and a nanoclaw-next.conf listing the same BIG_MODEL plus smaller ones.
set -euo pipefail

cap="${1:?memory cap, e.g. 1536M}"
model="${2:?path to the large model}"
prompt="${3:?prompt text}"
runs="${4:-10}"
ctx="${CTX:-4096}"
tokens="${TOKENS:-128}"
llama="${LLAMA_BIN:-llama-completion}"
out="state/compare-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"

capped() {
	systemd-run --user --scope --quiet -p MemoryMax="$cap" -p MemorySwapMax=0 "$@"
}

echo "[compare] baseline: $llama, fixed model, ctx=$ctx, cap=$cap"
echo "run,ok,exit,wall_ms" >"$out/baseline.csv"
for i in $(seq 1 "$runs"); do
	start=$(date +%s%3N)
	set +e
	capped "$llama" -m "$model" -c "$ctx" -n "$tokens" -p "$prompt" --no-display-prompt >/dev/null 2>"$out/baseline-$i.err"
	code=$?
	set -e
	end=$(date +%s%3N)
	ok=$([ "$code" -eq 0 ] && echo 1 || echo 0)
	echo "$i,$ok,$code,$((end - start))" >>"$out/baseline.csv"
	echo "  run $i: exit $code ($((end - start)) ms)"
done

echo "[compare] nanoclaw-next: adaptive, same cap"
capped nanoclaw-next bench --prompt "$prompt" --runs "$runs" --ctx "$ctx" --tokens "$tokens" --out "$out/nanoclaw.csv"

echo
echo "[compare] baseline success: $(awk -F, 'NR>1 && $2==1' "$out/baseline.csv" | wc -l)/$runs"
echo "[compare] nanoclaw success: $(awk -F, 'NR>1 && $2==1' "$out/nanoclaw.csv" | wc -l)/$runs"
echo "[compare] raw data in $out/"
