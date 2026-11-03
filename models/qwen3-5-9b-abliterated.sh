#!/usr/bin/env bash
set -e

cd /home/djamla/code/ik_llama.cpp/build/bin

LOG=/home/djamla/llama-server.log

setsid nohup ./llama-server \
    -m /home/djamla/.cache/huggingface/hub/models--mradermacher--Huihui-Qwen3.5-9B-abliterated-GGUF/snapshots/419ca34f424adbd9276c09e0271cb6b718e8da1d/Huihui-Qwen3.5-9B-abliterated.Q4_K_M.gguf \
    -ngl 999 -fa on -c 262144 \
    -ctk q8_0 -ctv q8_0 -ub 1024 \
    -t 8 -np 1 --jinja \
    --reasoning-format deepseek \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --alias qwen3.5-9b \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "llama-server started (PID $!), logging to $LOG"
