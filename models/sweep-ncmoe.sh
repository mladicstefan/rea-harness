#!/usr/bin/env bash
# Benchmark MoE expert placement: for a hybrid GPU+CPU MoE launch script, try a
# range of -ncmoe values (how many layers keep their experts in RAM) at one or
# more context sizes, and report generation/prompt speed and VRAM for each.
#
# Lower ncmoe = more experts on the GPU = faster, until VRAM runs out. This
# finds the fastest value that still fits your card.
#
# Usage:
#   ./models/sweep-ncmoe.sh <model-script> [--ctx N[,N...]] [--ncmoe V[,V...]] [--gen N] [--prompt N]
#
# Examples:
#   ./models/sweep-ncmoe.sh models/qwen3-6-35b-a3b-abliterated.sh
#   ./models/sweep-ncmoe.sh models/qwen3-6-35b-a3b-abliterated.sh --ctx 131072,65536 --ncmoe cmoe,30,26,23,21
#
# The model script must honor the NCMOE and CTX environment variables (as
# models/qwen3-6-35b-a3b-abliterated.sh does). Requires: curl, jq, nvidia-smi,
# python3. WARNING: this stops any running llama-server (it needs the GPU and
# port 8080 to itself) and leaves it stopped when done.
set -euo pipefail

PORT=8080
HEALTH="http://127.0.0.1:$PORT"

die() { echo "$*" >&2; exit 1; }
for dep in curl jq nvidia-smi python3; do command -v "$dep" >/dev/null || die "missing dependency: $dep"; done

SCRIPT="${1:-}"; shift || true
[ -n "$SCRIPT" ] && [ -f "$SCRIPT" ] || die "usage: $0 <model-script> [--ctx ...] [--ncmoe ...] [--gen N] [--prompt N]"

CTXS="262144"
NCMOES="cmoe,30,26,23,21"
GEN=200
PROMPT_WORDS=1500
while [ $# -gt 0 ]; do
  case "$1" in
    --ctx)    CTXS="$2"; shift 2 ;;
    --ncmoe)  NCMOES="$2"; shift 2 ;;
    --gen)    GEN="$2"; shift 2 ;;
    --prompt) PROMPT_WORDS="$2"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

flag() { sed -nE "s/.*[[:space:]]$2[[:space:]]+([^[:space:]]+).*/\1/p" "$1" | head -1; }
ALIAS="$(flag "$SCRIPT" --alias)"; [ -n "$ALIAS" ] || ALIAS="local"

TMP="$(mktemp -d)"; trap 'pkill -x llama-server 2>/dev/null || true; rm -rf "$TMP"' EXIT
# Build a fixed benchmark request (deterministic filler prompt).
python3 - "$TMP/bench.json" "$ALIAS" "$GEN" "$PROMPT_WORDS" <<'PY'
import json,sys,random
out,alias,gen,words=sys.argv[1],sys.argv[2],int(sys.argv[3]),int(sys.argv[4])
random.seed(1)
filler=' '.join(str(random.randint(100,999)) for _ in range(words))
json.dump({"model":alias,"max_tokens":gen,"temperature":0,
  "chat_template_kwargs":{"enable_thinking":False},
  "messages":[{"role":"user","content":"Reply with the single word OK, nothing else.\n"+filler}]},
  open(out,"w"))
PY

vram() { nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits | tr -d ' '; }

printf '%-8s %-7s %8s %8s %12s %12s\n' ctx ncmoe TG PP "VRAM_used" "VRAM_free"
echo "-------------------------------------------------------------------"

IFS=',' read -ra CTX_ARR <<< "$CTXS"
IFS=',' read -ra NC_ARR  <<< "$NCMOES"
for ctx in "${CTX_ARR[@]}"; do
  for nc in "${NC_ARR[@]}"; do
    pkill -x llama-server 2>/dev/null || true
    while pgrep -x llama-server >/dev/null; do sleep 0.5; done
    sleep 1
    CTX="$ctx" NCMOE="$nc" bash "$SCRIPT" >/dev/null 2>&1 || true
    ok=0
    for _ in $(seq 1 300); do
      curl -fsS --max-time 2 "$HEALTH/health" >/dev/null 2>&1 && { ok=1; break; }
      pgrep -x llama-server >/dev/null || break
      sleep 1
    done
    if [ "$ok" -eq 0 ]; then
      printf '%-8s %-7s %8s %8s %12s %12s\n' "$ctx" "$nc" "-" "-" "FAILED/OOM" "-"
      pkill -x llama-server 2>/dev/null || true
      continue
    fi
    sleep 2
    uf="$(vram)"; used="${uf%%,*}"; free="${uf##*,}"
    r="$(curl -sS --max-time 600 "$HEALTH/v1/chat/completions" -H 'content-type: application/json' -d @"$TMP/bench.json" || echo '{}')"
    tg="$(echo "$r" | jq -r '(.timings.predicted_per_second // empty) | if . then (.*10|round/10) else "err" end' 2>/dev/null || echo err)"
    pp="$(echo "$r" | jq -r '(.timings.prompt_per_second   // empty) | if . then (.*10|round/10) else "err" end' 2>/dev/null || echo err)"
    [ -n "$tg" ] || tg=err; [ -n "$pp" ] || pp=err
    printf '%-8s %-7s %8s %8s %12s %12s\n' "$ctx" "$nc" "$tg" "$pp" "${used}MiB" "${free}MiB"
    pkill -x llama-server 2>/dev/null || true
  done
done

echo "-------------------------------------------------------------------"
echo "Pick the lowest ncmoe whose VRAM_free stays comfortable (~300MiB+ headroom)."
