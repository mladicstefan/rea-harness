#!/usr/bin/env bash
set -e

cd /home/djamla/code/ik_llama.cpp/build/bin

LOG=/home/djamla/llama-server.log

setsid nohup ./llama-server \
    -m /home/djamla/.cache/huggingface/hub/models--huihui-ai--Huihui-Qwen3.8-27B-abliterated-GGUF/snapshots/b146b417080fd3e0e842e9539e69921707360aae/Huihui-Qwen3.8-27B-abliterated-UD-IQ4_XS.gguf \
    -ngl 999 -fa on -c 32768 \
    -ctk q8_0 -ctv q8_0 -ub 512 \
    -t 8 -np 1 --jinja \
    --reasoning-format deepseek \
    --chat-template-kwargs '{"reasoning_effort":"medium","preserve_thinking":false}' \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --alias qwen3.8-27b \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "llama-server started (PID $!), logging to $LOG"
