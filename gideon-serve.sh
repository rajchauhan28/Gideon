#!/usr/bin/env bash
# Launch llama-server (turboquant + CUDA) for Gideon, with a model profile.
#
#   ./gideon-serve.sh [glm|gemma]      (default: glm)
#
# Benchmarked on an RTX 4050 Laptop (6 GB VRAM):
#   gemma  Gemma E4B Q5_K_M    full GPU offload, ~4.1 GB VRAM, ~43 tok/s.
#          Fast; weaker reasoning; tool-call format inconsistent (parser copes).
#   glm    GLM-4.7-Flash 23B   MoE experts on CPU via --n-cpu-moe, ~3.9 GB VRAM,
#          ~25 tok/s. Strong reasoning + clean tool-calling. Recommended brain.
# Both leave ~2 GB VRAM free for the desktop. Override anything via env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="${GIDEON_MODELS_DIR:-/home/reign/ddrive/GenAI/models}"
PROFILE="${1:-${GIDEON_PROFILE:-glm}}"

# Find the turboquant llama-server (installed to PATH, or inside the fork).
SERVER="${LLAMA_SERVER_BIN:-}"
if [[ -z "$SERVER" ]]; then
  for c in \
    "$(command -v llama-server || true)" \
    "$ROOT/llama-cpp-turboquant/build/bin/llama-server" \
    "$ROOT/llama-cpp-turboquant/build/llama-server"; do
    [[ -n "$c" && -x "$c" ]] && SERVER="$c" && break
  done
fi
if [[ -z "$SERVER" || ! -x "$SERVER" ]]; then
  echo "llama-server binary not found. Build it first, or set LLAMA_SERVER_BIN." >&2
  exit 1
fi

# Shared defaults. KV uses TurboQuant's asymmetric ladder: K stays high-precision
# (never turbo); V uses turbo4 (lightest, beats q4_0 fidelity). Ratchet V to
# turbo3/turbo2 for more compression once output quality is verified.
PORT="${PORT:-8080}"
CTX="${CTX:-8192}"
KV_K="${KV_K:-q8_0}"
KV_V="${KV_V:-turbo4}"

case "$PROFILE" in
  gemma)
    MODEL="${GIDEON_MODEL_PATH:-$MODELS_DIR/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive-Q5_K_M.gguf}"
    # turboquant weight compression lets all layers fit; full GPU offload.
    OFFLOAD=(--n-gpu-layers "${NGL:-99}")
    ;;
  glm)
    MODEL="${GIDEON_MODEL_PATH:-$MODELS_DIR/GLM-4.7-Flash-REAP-23B-A3B-IQ4_XS.gguf}"
    # MoE: attention on GPU, experts of the first N layers on CPU RAM.
    # n-cpu-moe 38 -> ~3.9 GB VRAM / ~1.9 GB free / ~25 tok/s. Lower N = faster
    # but tighter VRAM (34 -> ~26.5 tok/s but only ~0.9 GB free).
    OFFLOAD=(--n-gpu-layers 99 --n-cpu-moe "${N_CPU_MOE:-38}")
    ;;
  *)
    echo "Unknown profile '$PROFILE'. Use: glm | gemma" >&2
    exit 1
    ;;
esac

if [[ ! -f "$MODEL" ]]; then
  echo "Model file not found: $MODEL" >&2
  exit 1
fi

echo "Gideon[$PROFILE] -> $SERVER"
echo "  model=$(basename "$MODEL")  ctx=$CTX  kv=$KV_K/$KV_V  port=$PORT  offload=${OFFLOAD[*]}"

exec "$SERVER" \
  --model "$MODEL" \
  --alias gideon \
  --host 127.0.0.1 --port "$PORT" \
  "${OFFLOAD[@]}" \
  --ctx-size "$CTX" \
  --flash-attn on \
  --cache-type-k "$KV_K" \
  --cache-type-v "$KV_V" \
  --no-webui
