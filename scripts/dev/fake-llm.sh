#!/bin/sh
# Stand-in for llama.cpp, for testing the engine without a real model.
# Accepts: -m MODEL -c CTX -n N [-f PROMPT_FILE]; reads the prompt on stdin.
# A model path containing "oom" simulates the kernel OOM killer (SIGKILL).
model=""
while [ $# -gt 0 ]; do
	case "$1" in
	-m) model="$2"; shift 2 ;;
	*) shift ;;
	esac
done

case "$model" in
*oom*) kill -9 $$ ;;
esac

prompt=$(cat)
sleep 0.2
case "$prompt" in
*"EXACTLY ONE unix command"*) echo "ls -la" ;;
*) printf '1. List the directory\n2. Report the result\n' ;;
esac
echo "llama_perf_context_print:        eval time =     200.00 ms /    20 runs   (   10.00 ms per token)" >&2
