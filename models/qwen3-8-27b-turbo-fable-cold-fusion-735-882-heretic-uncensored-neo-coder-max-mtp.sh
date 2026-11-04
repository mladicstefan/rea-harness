#!/usr/bin/env bash
set -e

cd /home/djamla/code/ik_llama.cpp/build/bin

LOG=/home/djamla/llama-server.log

# DavidAU Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP.
# IQ2_M (~12GB). Card defaults: thinking on, reasoning_effort=xhigh, preserve_thinking on
# (so no --chat-template-kwargs override). MTP self-speculation via its own NextN head.
# Card: keep temp <=1 and rep pen off (default) or MTP acceptance drops.
setsid nohup ./llama-server \
    -m /home/djamla/.cache/huggingface/hub/models--DavidAU--Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP-GGUF/snapshots/b9bce7e859c9b5047aca884e5bff76f8a0443de1/Qwen3.8-27B-TurboFCFusion-735-882-Here-Uncen-NEO-CODER-MAX-MTP-IQ2_M.gguf \
    -ngl 999 -fa on -c 81920 \
    -ctk q4_0 -ctv q4_0 -ub 512 \
    -t 8 -np 1 --jinja \
    --spec-type mtp:n_max=1,p_min=0.0 \
    --reasoning-format deepseek \
    --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --alias Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "llama-server started (PID $!), logging to $LOG"
