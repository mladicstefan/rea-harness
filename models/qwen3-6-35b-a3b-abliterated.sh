#!/usr/bin/env bash
# Qwen3.6-35B-A3B (MoE, ~3B active) on ik_llama.cpp, hybrid GPU+CPU.
# RTX 4070 Ti SUPER 16GB + Ryzen 3700X (dual-channel DDR4) + 46GB RAM.
#
# Strategy: all non-expert weights + KV cache on GPU (-ngl 99), expert FFN
# tensors in RAM. NCMOE = how many of the 40 layers keep experts on CPU; lower
# = more experts on GPU = faster. Measured on RTX 4070 Ti SUPER 16GB + Ryzen
# 3700X + 48GB DDR4-3000, Q4_K_M, KV q8_0 (TG t/s / VRAM used / free):
#   128k: cmoe 54/4.1G/11.9  | ncmoe 30 65/8.8G/7.2 | 23 69/12.1G/4.0 | 21 79/12.9G/3.1
#    64k: cmoe 53/3.5G/12.6  | ncmoe 24 74/10.9G/5.1 | 20 75/12.7G/3.3 | 17 85/14.1G/1.9 | 15 90/14.9G/1.1
# KV cache is cheap here (2 KV heads, q8_0): ~1.36GB at 128k, ~2.72GB at 256k.
# Default below = 256k (native), ncmoe 23 (~13.4GB used, ~2.6GB free). Override at launch:
#   NCMOE=21 ./models/qwen3-6-35b-a3b-abliterated.sh   # faster, less headroom
#   NCMOE=cmoe ./models/qwen3-6-35b-a3b-abliterated.sh # all experts on CPU
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
NCMOE="${NCMOE:-23}"
if [ "$NCMOE" = cmoe ] || [ -z "$NCMOE" ]; then
    MOE_ARGS=(-cmoe)
else
    MOE_ARGS=(-ncmoe "$NCMOE")
fi

# Context size. Overridable so sweep-ncmoe.sh can benchmark different windows;
# start.sh reads this default to configure Pi's context window.
CTX="${CTX:-262144}"

setsid nohup ./llama-server \
    -m "$MODEL" \
    -ngl 99 -fa on -c "$CTX" \
    "${MOE_ARGS[@]}" \
    -ctk q8_0 -ctv q8_0 -ub 512 \
    -t 8 -tb 16 -np 1 --jinja \
    --reasoning-format deepseek \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --alias qwen3.6-35b-a3b \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "llama-server started (PID $!), logging to $LOG"
echo "MoE placement: ${MOE_ARGS[*]}   model: $MODEL"
