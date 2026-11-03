#!/usr/bin/env bash
# Qwen3.6-35B-A3B (MoE, ~3B active) on ik_llama.cpp, hybrid GPU+CPU.
# RTX 4070 Ti SUPER 16GB + Ryzen 3700X (dual-channel DDR4) + 46GB RAM.
#
# Strategy: all non-expert weights + KV cache on GPU (-ngl 99), expert FFN
# tensors in RAM. NCMOE controls how many layers' experts stay on CPU: lower
# it to push more experts into spare VRAM (faster generation) until you OOM.
#   -cmoe  (NCMOE unset) = ALL experts on CPU: safe baseline, slowest TG.
#   -ncmoe N             = experts of the first N layers on CPU, rest on GPU.
# Tune: start with the baseline, watch `nvidia-smi` headroom, then set NCMOE
# to (layers - k) and lower k until free VRAM is ~300-500 MiB.
set -e

cd /home/djamla/code/ik_llama.cpp/build/bin

LOG=/home/djamla/llama-server.log

# Resolve the GGUF from the HF cache (snapshot hash varies; model may still be
# downloading — this picks the first matching finished file).
MODEL=$(find /home/djamla/.cache/huggingface/hub/models--wangzhang--Qwen3.6-35B-A3B-abliterated-GGUF/snapshots \
    -name '*Q4_K_M*.gguf' 2>/dev/null | sort | head -1)
if [ -z "$MODEL" ]; then
    echo "Qwen3.6-35B-A3B Q4_K_M GGUF not found (still downloading?)" >&2
    exit 1
fi

# Experts-on-CPU knob. Leave empty for the all-CPU baseline (-cmoe); set to a
# number to keep only the first N layers' experts on CPU. Override at launch:
#   NCMOE=40 ./models/qwen3-6-35b-a3b-abliterated.sh
NCMOE="${NCMOE:-}"
if [ -n "$NCMOE" ]; then
    MOE_ARGS=(-ncmoe "$NCMOE")
else
    MOE_ARGS=(-cmoe)
fi

setsid nohup ./llama-server \
    -m "$MODEL" \
    -ngl 99 -fa on -c 32768 \
    "${MOE_ARGS[@]}" \
    -ctk q8_0 -ctv q8_0 -ub 512 \
    -t 8 -tb 16 -np 1 --jinja \
    --reasoning-format deepseek \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --alias qwen3.6-35b-a3b \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "llama-server started (PID $!), logging to $LOG"
echo "MoE placement: ${MOE_ARGS[*]}   model: $MODEL"
