#!/usr/bin/env bash
# Sweep --n-gpu-layers to find the largest GPU offload that still leaves VRAM
# headroom on the RTX 4050 (6 GB). For each candidate it boots llama-server,
# measures peak VRAM, runs a short prompt, records tokens/sec, then stops.
#
# Usage:  ./bench-offload.sh [headroom_MiB]
#   headroom_MiB: VRAM to keep free for the desktop/KV growth (default 900)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEADROOM="${1:-900}"
PORT=8099
CTX="${CTX:-8192}"
CANDIDATES=(${NGL_LIST:-20 24 28 32 36 40 43})

total_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
echo "GPU total: ${total_vram} MiB   target free: >=${HEADROOM} MiB   ctx=${CTX}"
printf "%-6s %-12s %-12s %-10s %s\n" "NGL" "peakVRAM" "freeVRAM" "tok/s" "verdict"
echo "----------------------------------------------------------------"

best=""
for ngl in "${CANDIDATES[@]}"; do
  PORT=$PORT NGL=$ngl CTX=$CTX "$ROOT/gideon-serve.sh" >/tmp/gideon-bench.log 2>&1 &
  pid=$!
  # wait for /health
  ready=0
  for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then ready=1; break; fi
    if ! kill -0 $pid 2>/dev/null; then break; fi
    sleep 1
  done

  if [[ $ready -eq 0 ]]; then
    printf "%-6s %-12s %-12s %-10s %s\n" "$ngl" "-" "-" "-" "FAILED (OOM/load err)"
    kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
    continue
  fi

  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
  free=$(( total_vram - used ))

  # one timed generation
  t0=$(date +%s.%N)
  resp=$(curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gideon","messages":[{"role":"user","content":"List three Arch Linux troubleshooting commands."}],"max_tokens":120,"temperature":0.2}' || echo '{}')
  t1=$(date +%s.%N)
  ntok=$(echo "$resp" | grep -o '"completion_tokens":[0-9]*' | grep -o '[0-9]*' | head -1)
  ntok=${ntok:-0}
  tps=$(awk -v a="$t0" -v b="$t1" -v n="$ntok" 'BEGIN{d=b-a; printf "%.1f", (d>0?n/d:0)}')

  verdict="ok"
  if (( free < HEADROOM )); then verdict="too tight (<${HEADROOM} free)"; else best=$ngl; fi
  printf "%-6s %-12s %-12s %-10s %s\n" "$ngl" "${used}MiB" "${free}MiB" "$tps" "$verdict"

  kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
  sleep 2
done

echo "----------------------------------------------------------------"
if [[ -n "$best" ]]; then
  echo "Recommended: NGL=$best  (largest offload leaving >=${HEADROOM} MiB free)"
  echo "Run:  NGL=$best ./gideon-serve.sh"
else
  echo "No candidate left enough headroom. Try a smaller quant (Q4_K_M) or lower CTX."
fi
