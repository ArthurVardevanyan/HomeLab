#!/usr/bin/env bash
# llm-bench.sh — Controlled benchmark for llama-swap speculative decoding.
#
# Usage:
#   ./scripts/llm-bench.sh [OPTIONS]
#
# Options:
#   -m MODEL      Model name from /running (default: 27b-gpu1)
#   -c CONTEXT    Prompt context length (default: 32000)
#   -n N          Generation length in tokens (default: 256)
#   -r REPS       Repetitions per point (default: 3)
#   -p PORT       Override port (bypasses /running resolution)
#   -o OUTPUT     CSV output file (default: stdout)
#   --novel       Use novel (non-repetitive) prompt corpus
#   --code        Use code-like (repetitive) prompt corpus (default)
#
# Examples:
#   # Baseline run on 27B, 32K context, novel corpus
#   ./scripts/llm-bench.sh -m 27b-gpu1 -c 32000 --novel
#
#   # Sweep n_min values (after adding --spec-ngram-mod-n-min to cmd_base)
#   ./scripts/llm-bench.sh -m 27b-gpu1 -c 64000 -r 5 --code
#
#   # Compare two configs (run once per config, diff the CSVs)
#   ./scripts/llm-bench.sh -m 27b-gpu1 -c 64000 -r 5 --code -o bench-nmax8.csv
#   # ... deploy new config ...
#   ./scripts/llm-bench.sh -m 27b-gpu1 -c 64000 -r 5 --code -o bench-nmax16.csv

set -o errexit -o nounset -o pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────
MODEL="27b-gpu1"
CONTEXT=32000
N_PREDICT=256
REPS=3
PORT=""
OUTPUT=""
CORPUS="code"
SEED=42

# ─── Arg parse ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m) MODEL="$2"; shift 2 ;;
    -c) CONTEXT="$2"; shift 2 ;;
    -n) N_PREDICT="$2"; shift 2 ;;
    -r) REPS="$2"; shift 2 ;;
    -p) PORT="$2"; shift 2 ;;
    -o) OUTPUT="$2"; shift 2 ;;
    --novel) CORPUS="novel"; shift ;;
    --code) CORPUS="code"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Resolve port ───────────────────────────────────────────────────────────
if [[ -z "${PORT}" ]]; then
  PORT=$(curl -s localhost:8080/running 2>/dev/null \
    | python3 -c "
import json, sys
running = json.load(sys.stdin).get('running', [])
for m in running:
    if m.get('model') == '${MODEL}' and m.get('state') == 'ready':
        print(m['proxy'].rsplit(':', 1)[1])
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || {
    echo "ERROR: model '${MODEL}' not found in /running (ready state)" >&2
    exit 1
  }
  echo "Resolved port ${PORT} for model ${MODEL}"
fi

BASE_URL="http://127.0.0.1:${PORT}"

# ─── Generate prompt ───────────────────────────────────────────────────────
# Repeats a seed phrase to fill the context window. Each corpus has a
# different token-length to avoid being too short/long after padding.
generate_prompt() {
  local target=$1
  local corpus=$2

  if [[ "${corpus}" == "code" ]]; then
    local phrase='fn main() { println!("hello"); let x = 42; return x; }\n'
    # ~12 tokens per iteration; pad to target
    local count=$(( target / 12 ))
  else
    local phrase='The quick brown fox jumps over the lazy dog. '
    # ~7 tokens per iteration; pad to target
    local count=$(( target / 7 ))
  fi

  local prompt=""
  for ((i=0; i<count; i++)); do
    prompt+="${phrase}"
  done
  # Trim to exact target (rough; llama.cpp will handle the rest)
  echo -n "${prompt}"
}

# ─── Scrape spec counters ──────────────────────────────────────────────────
scrape_counters() {
  local port=$1
  curl -s "http://127.0.0.1:${port}/metrics" 2>/dev/null \
    | grep -E '^llamacpp:(spec_decode_num_drafts_total|spec_decode_num_accepted_tokens_total|spec_decode_num_draft_tokens_total|tokens_predicted_total|n_decode_total|predicted_tokens_seconds)' \
    | sed "s/^/${port}	/"
}

parse_counter() {
  local name=$1
  local counters=$2
  echo "${counters}" | grep "${name} " | tail -1 | awk '{print $2}'
}

# ─── Run one request ───────────────────────────────────────────────────────
run_one() {
  local port=$1
  local prompt=$2
  local n_predict=$3
  local seed=$4

  local start end elapsed
  start=$(date +%s%N)

  local response
  response=$(curl -s -X POST "${BASE_URL}/completion" \
    -H "Content-Type: application/json" \
    -d "{
      \"prompt\": \"${prompt:0:50000}\",
      \"n_predict\": ${n_predict},
      \"temperature\": 0.0,
      \"seed\": ${seed},
      \"cache_prompt\": false,
      \"top_k\": 40,
      \"top_p\": 0.95,
      \"repeat_penalty\": 1.1
    }" 2>/dev/null) || {
    echo "FAIL"
    return
  }

  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))  # ms

  # Extract gen_tokens from response (approximate — the response is a llama.cpp stream)
  local gen_tokens
  gen_tokens=$(echo "${response}" | grep -o '"tokens_predicted": *[0-9]*' | tail -1 | grep -o '[0-9]*')
  gen_tokens=${gen_tokens:-0}

  echo "${elapsed}	${gen_tokens}"
}

# ─── Main ──────────────────────────────────────────────────────────────────
echo "=== llm-bench ==="
echo "Model:  ${MODEL}"
echo "Port:   ${PORT}"
echo "Context: ${CONTEXT}"
echo "Gen len: ${N_PREDICT}"
echo "Reps:   ${REPS}"
echo "Corpus: ${CORPUS}"
echo ""

# Pre-run metrics
PRE_METRICS=$(scrape_counters "${PORT}")

# Generate prompt
echo "Generating ${CONTEXT}-token prompt (${CORPUS} corpus)..."
PROMPT=$(generate_prompt "${CONTEXT}" "${CORPUS}")
PROMPT_LEN=${#PROMPT}
echo "Prompt length: ${PROMPT_LEN} chars"
echo ""

# Run repetitions
echo "Running ${REPS} repetitions..."
echo ""

declare -a DURATIONS
declare -a TOKENS

for ((r=0; r<REPS; r++)); do
  echo "  Rep ${r}..."
  result=$(run_one "${PORT}" "${PROMPT}" "${N_PREDICT}" "${SEED}")

  if [[ "${result}" == "FAIL" ]]; then
    echo "    FAILED"
    continue
  fi

  duration=$(echo "${result}" | cut -f1)
  gen_tok=$(echo "${result}" | cut -f2)

  DURATIONS+=("${duration}")
  TOKENS+=("${gen_tok}")
  echo "    ${duration} ms, ${gen_tok} tokens generated"
done

# Post-run metrics
POST_METRICS=$(scrape_counters "${PORT}")

# ─── Compute aggregates ───────────────────────────────────────────────────
if [[ ${#DURATIONS[@]} -eq 0 ]]; then
  echo "No successful runs." >&2
  exit 1
fi

# Median duration (ms)
median_dur() {
  local -a sorted
  mapfile -t sorted < <(printf '%s\n' "${@}" | sort -n) || true
  local n=${#sorted[@]}
  if (( n % 2 == 1 )); then
    echo "${sorted[$((n/2))]}"
  else
    local a=${sorted[$((n/2 - 1))]}
    local b=${sorted[$((n/2))]}
    echo "scale=1; (${a} + ${b}) / 2" | bc
  fi
}

median_tok() {
  median_dur "${@}"
}

med_dur_ms=$(median_dur "${DURATIONS[@]}")
med_tok=$(median_tok "${TOKENS[@]}")
med_tps=$(echo "scale=2; ${med_tok} / (${med_dur_ms} / 1000)" | bc 2>/dev/null || echo "N/A")

# Spec counters delta
post_drafts=$(parse_counter "spec_decode_num_drafts_total" "${POST_METRICS}")
post_accepted=$(parse_counter "spec_decode_num_accepted_tokens_total" "${POST_METRICS}")
post_draft_tokens=$(parse_counter "spec_decode_num_draft_tokens_total" "${POST_METRICS}")
post_predicted=$(parse_counter "tokens_predicted_total" "${POST_METRICS}")

pre_drafts=$(parse_counter "spec_decode_num_drafts_total" "${PRE_METRICS}")
pre_accepted=$(parse_counter "spec_decode_num_accepted_tokens_total" "${PRE_METRICS}")
pre_draft_tokens=$(parse_counter "spec_decode_num_draft_tokens_total" "${PRE_METRICS}")
pre_predicted=$(parse_counter "tokens_predicted_total" "${PRE_METRICS}")

delta_drafts=$((post_drafts - pre_drafts))
delta_accepted=$((post_accepted - pre_accepted))
delta_draft_tok=$((post_draft_tokens - pre_draft_tokens))
delta_predicted=$((post_predicted - pre_predicted))

acceptance="N/A"
mean_draft="N/A"
if [[ ${delta_draft_tok} -gt 0 && ${delta_drafts} -gt 0 ]]; then
  acceptance=$(echo "scale=1; ${delta_accepted} * 100 / ${delta_draft_tok}" | bc 2>/dev/null || echo "N/A")
  mean_draft=$(echo "scale=2; (${delta_accepted} + ${delta_drafts}) / ${delta_drafts}" | bc 2>/dev/null || echo "N/A")
fi

# ─── Output ───────────────────────────────────────────────────────────────
CSV_HEADER="model,port,context,n_predict,reps,corpus,seed,median_dur_ms,median_gen_tok,median_tps,delta_drafts,delta_accepted,delta_draft_tokens,acceptance_pct,mean_draft_len,spec_contrib_pct"
CSV_ROW="${MODEL},${PORT},${CONTEXT},${N_PREDICT},${REPS},${CORPUS},${SEED},${med_dur_ms},${med_tok},${med_tps},${delta_drafts},${delta_accepted},${delta_draft_tok},${acceptance},${mean_draft},${delta_predicted:-0}"

if [[ -n "${OUTPUT}" ]]; then
  if [[ ! -f "${OUTPUT}" ]]; then
    echo "${CSV_HEADER}" > "${OUTPUT}"
  fi
  echo "${CSV_ROW}" >> "${OUTPUT}"
  echo "Results written to ${OUTPUT}"
else
  echo "${CSV_HEADER}"
  echo "${CSV_ROW}"
fi

echo ""
echo "=== Summary ==="
echo "Median duration:  ${med_dur_ms} ms"
echo "Median gen tokens: ${med_tok}"
echo "Median throughput: ${med_tps} t/s"
echo "Spec drafts:       ${delta_drafts} (acceptance: ${acceptance}%, mean draft: ${mean_draft} tokens)"
echo "Spec contribution: ${delta_predicted:-0} total predicted tokens"
