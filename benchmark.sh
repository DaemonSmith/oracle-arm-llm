#!/usr/bin/env bash
# llama_bench_ext_with_avg.sh
# Extended benchmark that appends per-run CSV rows (unchanged) AND a per-batch summary row.
# Requirements: curl, jq, bc, docker
set -euo pipefail

OUT_CSV="${OUT_CSV:-./llama_bench_results.csv}"
OUT_LOG="${OUT_LOG:-./llama_bench_details.log}"
ENDPOINT_BASE="${ENDPOINT_BASE:-http://localhost:8080}"
CONTAINER_NAME="${CONTAINER_NAME:-llama-server}"
RUNS="${RUNS:-5}"
PROMPT="${PROMPT:-Write a short story about a robot learning to paint. Make it ~100 words.}"
MAX_TOKENS="${MAX_TOKENS:-150}"
TEMPERATURE="${TEMPERATURE:-0.1}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-2}"
TIMEOUT_CURL="${TIMEOUT_CURL:-30}"

mkdir -p "$(dirname "$OUT_CSV")"
touch "$OUT_LOG"

# CSV header (keeps same columns)
if ! grep -q '^timestamp,' "$OUT_CSV" 2>/dev/null || [ ! -s "$OUT_CSV" ]; then
  cat > "$OUT_CSV" <<'CSVHEAD'
timestamp,run,model,http_code,time_namelookup,time_connect,time_pretransfer,time_starttransfer,time_total,bytes_downloaded,tokens_returned,tokens_per_sec
CSVHEAD
fi

echo "Benchmark start: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$OUT_LOG"
echo "Endpoint base: $ENDPOINT_BASE" | tee -a "$OUT_LOG"
echo "Prompt preview: ${PROMPT:0:120}..." | tee -a "$OUT_LOG"
echo "Runs: $RUNS, max_tokens: $MAX_TOKENS, temp: $TEMPERATURE" | tee -a "$OUT_LOG"
echo "" >> "$OUT_LOG"

# helper: get model name (symlink-aware) - copy the function you already use or minimal version:
get_model_name() {
  local base="${ENDPOINT_BASE:-http://localhost:8080}"
  local models_dir="${MODELS_DIR:-/home/ubuntu/ai/models}"
  local container="${CONTAINER_NAME:-llama-server}"
  local api_json api_id resolved realpath reply model_from_model

  api_json=$(curl -sSf --max-time 3 "${base}/v1/models" 2>/dev/null || true)
  if [ -n "$api_json" ]; then
    api_id=$(echo "$api_json" | jq -r '(.models[0].id // .models[0].model // .models[0].name // .model // .name // "")' 2>/dev/null || true)
    if [ -n "$api_id" ]; then
      if [[ ! "$api_id" =~ (^/models/|/current$|^current$) ]]; then
        echo "$api_id (from /v1/models)"
        return 0
      fi
      api_id="${api_id##*/}"
    fi
  fi

  if [ -L "${models_dir}/current" ] || [ -e "${models_dir}/current" ]; then
    if realpath=$(readlink -f "${models_dir}/current" 2>/dev/null || true); then
      if [ -n "$realpath" ]; then
        echo "$(basename "$realpath") (from host symlink ${models_dir}/current -> $realpath)"
        return 0
      fi
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    if docker ps -q --filter "name=${container}" | grep -q .; then
      resolved=$(docker exec -i "$container" sh -c 'readlink -f /models/current 2>/dev/null || true' 2>/dev/null || true)
      if [ -n "$resolved" ]; then
        echo "$(basename "$resolved") (from container ${container} -> $resolved)"
        return 0
      fi
    fi
  fi

  # last resort: ask model (may hallucinate)
  if curl -sSf --max-time 3 "${base}/v1/chat/completions" >/dev/null 2>&1; then
    reply=$(curl -sS -X POST "${base}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      --max-time 6 \
      -d '{"model":"current","messages":[{"role":"system","content":"You are a model instance. Reply with the exact model filename loaded (one short token), for example Qwen3-14B-Q4_K_M.gguf. Reply with only that filename and nothing else."},{"role":"user","content":"What is the exact model filename you have loaded?"}],"max_tokens":8,"temperature":0}' 2>/dev/null || true)
    if [ -n "$reply" ]; then
      model_from_model=$(echo "$reply" | jq -r '.choices[0].message.content // .choices[0].text // ""' 2>/dev/null || true)
      model_from_model=$(echo "$model_from_model" | tr -d '\r\n' | awk '{print $1}')
      if [ -n "$model_from_model" ]; then
        echo "$model_from_model (reported by model — verify!)"
        return 0
      fi
    fi
  fi

  echo "current (unresolved pointer — symlink not accessible)"
  return 1
}

MODEL_NAME="$(get_model_name)"
echo "Detected model name: $MODEL_NAME" | tee -a "$OUT_LOG"
echo "" >> "$OUT_LOG"

# Record starting CSV line count so we can compute averages over just this batch
START_CSV_LINES=$(wc -l < "$OUT_CSV" || echo 0)
# Run tests
for i in $(seq 1 "$RUNS"); do
  echo "=== Run $i/$RUNS ($(date -u +"%Y-%m-%dT%H:%M:%SZ")) ===" | tee -a "$OUT_LOG"
  RUN_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # build payload (try chat endpoint)
  BODY=$(jq -n --arg model "current" --arg prompt "$PROMPT" --argjson max_tokens "$MAX_TOKENS" --argjson temp "$TEMPERATURE" \
    '{model:$model,messages:[{role:"user",content:$prompt}],max_tokens:$max_tokens,temperature:$temp}')

  TMPRESP="$(mktemp)"
  CURL_WOUT="%{http_code},%{time_namelookup},%{time_connect},%{time_pretransfer},%{time_starttransfer},%{time_total},%{size_download}"

  URL="$ENDPOINT_BASE/v1/chat/completions"
  echo "Requesting $URL ..." | tee -a "$OUT_LOG"

  TIMING_LINE=$(curl -sS -o "$TMPRESP" -w "$CURL_WOUT" -X POST \
    -H "Content-Type: application/json" \
    --max-time "$TIMEOUT_CURL" \
    --data-binary "$BODY" \
    "$URL" 2>/dev/null) || TIMING_LINE="000,0,0,0,0,0,0"

  IFS=',' read -r HTTP_CODE T_NAMEL T_CONN T_PRETR T_TTFB T_TOTAL SIZE_DL <<<"$TIMING_LINE"
  HTTP_CODE="${HTTP_CODE:-000}"
  T_NAMEL="${T_NAMEL:-0}"
  T_CONN="${T_CONN:-0}"
  T_PRETR="${T_PRETR:-0}"
  T_TTFB="${T_TTFB:-0}"
  T_TOTAL="${T_TOTAL:-0}"
  SIZE_DL="${SIZE_DL:-0}"

  # tokens extraction (best effort)
  TOKENS=0
  if jq -e 'has("usage")' "$TMPRESP" >/dev/null 2>&1; then
    TOKENS=$(jq -r '.usage.total_tokens // .usage.completion_tokens // .usage.tokens // 0' "$TMPRESP" 2>/dev/null || echo 0)
  else
    TOKENS=$(jq -r '.choices[0].length // .choices[0].finish_reason // 0' "$TMPRESP" 2>/dev/null || echo 0)
  fi
  if [ -z "$TOKENS" ] || [ "$TOKENS" = "null" ] || [ "$TOKENS" -eq 0 ] 2>/dev/null; then
    RESP_TEXT=$(jq -r '.choices[0].message.content // .choices[0].text // ""' "$TMPRESP" 2>/dev/null || true)
    if [ -n "$RESP_TEXT" ]; then
      WORDS=$(echo "$RESP_TEXT" | wc -w)
      TOKENS=$(awk -v w=$WORDS 'BEGIN{printf("%.0f", w*1.3)}')
    else
      TOKENS=0
    fi
  fi

  TOKENS_PER_SEC="0.00"
  if awk "BEGIN {exit !($T_TOTAL > 0)}"; then
    TOKENS_PER_SEC=$(awk -v t="$TOKENS" -v s="$T_TOTAL" 'BEGIN{ if(s>0) printf("%.2f", t/s); else print "0.00"}')
  fi

  # append run to CSV (preserve original format)
  printf '%s,%d,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%.2f\n' \
    "$RUN_TS" "$i" "$MODEL_NAME" "$HTTP_CODE" "$T_NAMEL" "$T_CONN" "$T_PRETR" "$T_TTFB" "$T_TOTAL" "$SIZE_DL" "$TOKENS" "$TOKENS_PER_SEC" \
    >> "$OUT_CSV"

  # human-readable details appended
  {
    echo "Run: $i / $RUNS  ts: $RUN_TS"
    echo "URL: $URL"
    echo "HTTP code: $HTTP_CODE"
    echo "timings (s) name_lookup/connect/pretransfer/TTFB/total: $T_NAMEL / $T_CONN / $T_PRETR / $T_TTFB / $T_TOTAL"
    echo "bytes downloaded: $SIZE_DL"
    echo "tokens returned (heuristic): $TOKENS"
    echo "tokens/sec (heuristic): $TOKENS_PER_SEC"
    echo "Response head (first 800 chars):"
    head -c 800 "$TMPRESP" | sed 's/$/\n/' || true
    echo ""
    echo "---- server logs tail (filtered) ----"
    if docker ps -q --filter "name=$CONTAINER_NAME" | grep -q .; then
      docker logs --tail 200 "$CONTAINER_NAME" 2>/dev/null | sed -n '1,400p' | egrep -i "print_timing|prompt eval time|eval time|tokens per second|slot update_slots|loading model" || true
    else
      echo "(container $CONTAINER_NAME not running or docker not available)"
    fi
    echo "---- end server logs ----"
    echo ""
    echo "-----------------------------------------------"
  } >> "$OUT_LOG"

  rm -f "$TMPRESP"
  sleep "$SLEEP_BETWEEN"
done

# --- compute averages for the block we just appended ---
END_CSV_LINES=$(wc -l < "$OUT_CSV" || echo 0)
NEW_LINES=$((END_CSV_LINES - START_CSV_LINES))
if [ "$NEW_LINES" -le 0 ]; then
  echo "No new CSV lines added; nothing to average." | tee -a "$OUT_LOG"
  exit 0
fi

# Grab the newly appended rows and compute stats.
# tokens_per_sec is last column (NF), time_total is NF-6, tokens_returned is NF-1
SUMMARY=$(tail -n "$NEW_LINES" "$OUT_CSV" | awk -F',' '
  BEGIN {
    sum=0; sumsq=0; n=0; min=1e18; max=0;
    sum_time=0; sum_tokens=0;
  }
  {
    val=$(NF); t=$(NF-6); tok=$(NF-1);
    # convert to numeric safely
    val = (val+0); t = (t+0); tok = (tok+0);
    sum += val; sumsq += (val*val); n++;
    if (val < min) min = val;
    if (val > max) max = val;
    sum_time += t; sum_tokens += tok;
  }
  END {
    if (n==0) {
      print "ERR:0";
      exit;
    }
    mean = sum / n;
    var = (sumsq - (sum*sum)/n) / n;
    if (var < 0) var = 0;
    sd = sqrt(var);
    mean_time = sum_time / n;
    mean_tokens = sum_tokens / n;
    # Print CSV-friendly summary: mean,sd,min,max,mean_time,mean_tokens,count
    printf("%.6f,%.6f,%.6f,%.6f,%.6f,%.2f,%d\n", mean, sd, min, max, mean_time, mean_tokens, n);
  }')

if [ -z "$SUMMARY" ] || [[ "$SUMMARY" == ERR:* ]]; then
  echo "Failed to compute summary." | tee -a "$OUT_LOG"
  exit 0
fi

MEAN=$(echo "$SUMMARY" | cut -d',' -f1)
SD=$(echo "$SUMMARY" | cut -d',' -f2)
MIN=$(echo "$SUMMARY" | cut -d',' -f3)
MAX=$(echo "$SUMMARY" | cut -d',' -f4)
MEAN_TIME=$(echo "$SUMMARY" | cut -d',' -f5)
MEAN_TOKENS=$(echo "$SUMMARY" | cut -d',' -f6)
COUNT=$(echo "$SUMMARY" | cut -d',' -f7)

# Append a summary row to the CSV so you can filter it later.
# We'll place "avg" in the run column and "AVG" in http_code to indicate this is a summary row.
SUMMARY_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
# Fill unused fields with zeros or placeholders; keep column alignment.
printf '%s,%s,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%.2f,%.2f\n' \
  "$SUMMARY_TS" "avg" "$MODEL_NAME" "AVG" 0 0 0 0 "$MEAN_TIME" 0 "$MEAN_TOKENS" "$MEAN" \
  >> "$OUT_CSV"

# Human-readable summary in the log
{
  echo ""
  echo "=== Batch summary for model: $MODEL_NAME ==="
  echo "Runs in batch: $COUNT"
  echo "Tokens/sec mean: $MEAN"
  echo "Tokens/sec stddev: $SD"
  echo "Tokens/sec min/max: $MIN / $MAX"
  echo "Average time_total (s): $MEAN_TIME"
  echo "Average tokens returned: $MEAN_TOKENS"
  echo "Summary row appended to CSV at: $SUMMARY_TS"
  echo "=== End batch summary ==="
  echo ""
} >> "$OUT_LOG"

echo "Benchmark finished at $(date -u +"%Y-%m-%dT%H:%M:%SZ")" | tee -a "$OUT_LOG"
echo "Results appended to: $OUT_CSV"
echo "Details appended to: $OUT_LOG"

# show the appended summary CSV lines (for quick glance)
echo ""
echo "Recent CSV results (last $((NEW_LINES+1)) lines):"
tail -n $((NEW_LINES+1)) "$OUT_CSV" | sed -n '1,200p'

exit 0

