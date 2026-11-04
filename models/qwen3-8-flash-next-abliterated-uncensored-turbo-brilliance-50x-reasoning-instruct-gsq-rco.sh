#!/usr/bin/env bash
# DavidAU Qwen3.8-Flash-Next Abliterated-Uncensored-Turbo-Brilliance-50x-Reasoning-Instruct
# GSQ-RCO, IQ3_S (~78GB, 2 shards) on Strata: hot experts on GPU, all experts mmap'd from RAM/SSD.
#
# Strata is driven by its serve/server.py plus a JSON config its setup wrote
# (strata-iq3_s.json, 64k context). This derives a 128k sibling config from it
# at launch, so setup reruns (calibrate, KV, vision) still carry over. KV is
# ~13 KB/token, so 128k takes ~0.85GB more VRAM than 64k out of the auto-sized
# expert cache (~10% fewer slots).
set -e

STRATA=/home/djamla/code/Strata
BASE=$STRATA/strata-iq3_s.json
CONF=$STRATA/strata-iq3_s.128k.json
LOG=/home/djamla/llama-server.log
ALIAS=Qwen3.8-Flash-Next-Abliterated-Uncensored-Turbo-Brilliance-50x-Reasoning-Instruct-GSQ-RCO
# start.sh reads these defaults to label the menu and configure Pi's context window.
CTX="${CTX:-131072}"

[ -f "$BASE" ] || { echo "Strata config not found: $BASE. Run Strata's setup first: cd $STRATA && ./setup.sh --setup" >&2; exit 1; }
# Sampling: DavidAU card defaults (temp 1.0, top_p 0.95, top_k 64, min_p 0.05, no
# repeat penalty; 0.6-0.7 temp if tool calls misfire). Without a `sampling` block
# Strata decodes greedy for requests that send no sampling keys (Pi sends none).
# top_k 64 is Strata's cap.
jq --arg ctx "$CTX" --arg alias "$ALIAS" --arg log "${CONF%.json}.log" \
    '(.args | index("--max-context")) as $i | .args[$i + 1] = $ctx | .model_name = $alias | .log = $log
     | .sampling = {temperature: 1.0, top_p: 0.95, top_k: 64, min_p: 0.05}' \
    "$BASE" >"$CONF"

cd "$STRATA"
# --host 0.0.0.0 so the container reaches it via host.docker.internal (no API key, like llama-server).
setsid nohup .venv/bin/python serve/server.py --engine strata --config "$CONF" \
    --host 0.0.0.0 --port 8080 >"$LOG" 2>&1 </dev/null &

echo "strata started (PID $!), logging to $LOG (engine log: ${CONF%.json}.log)"
