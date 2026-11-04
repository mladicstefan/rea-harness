#!/usr/bin/env bash
# Pick a model, start its server (ik_llama.cpp llama-server or Strata), point Pi
# at it and attach. Model name, context size and engine are read from the
# models/*.sh scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/home/djamla/llama-server.log
HEALTH=http://127.0.0.1:8080
STRATA_SERVER="serve/server.py --engine strata"  # matches relative and absolute launches

flag() { sed -nE "s/.*[[:space:]]$2[[:space:]]+([^[:space:]]+).*/\1/p" "$1" | head -1; }
set_env() { sed -i -E "s|^$1=.*|$1=$2|" .env; }
# Context: scripts with a `CTX="${CTX:-N}"` default expose it there; dense
# scripts just hardcode `-c N`.
ctx_of() { local c; c="$(sed -nE 's/^CTX="\$\{CTX:-([0-9]+)\}".*/\1/p' "$1" | head -1)"; [ -n "$c" ] || c="$(flag "$1" -c)"; echo "$c"; }
# Alias: Strata scripts set `ALIAS=` (its model name lives in a JSON config); llama-server scripts pass --alias.
alias_of() { local a; a="$(sed -nE 's/^ALIAS=(.*)/\1/p' "$1" | head -1)"; [ -n "$a" ] || a="$(flag "$1" --alias)"; echo "$a"; }
engine_of() { if grep -q serve/server.py "$1"; then echo strata; else echo ik_llama.cpp; fi; }
server_alive() { case "$1" in strata) pgrep -f "$STRATA_SERVER" ;; *) pgrep -x llama-server ;; esac >/dev/null; }

scripts=(); labels=()
for f in models/*.sh; do
  case "$f" in models/start.sh|models/sweep-ncmoe.sh) continue ;; esac
  scripts+=("$f")
  labels+=("$(alias_of "$f") ($(( $(ctx_of "$f") / 1024 ))k context, $(engine_of "$f"))")
done

PS3="Model: "
COLUMNS=1  # one option per line
script=""
select label in "${labels[@]}"; do
  if [ -n "${label:-}" ]; then script="${scripts[REPLY-1]}"; break; fi
done
[ -n "$script" ] || exit 1

alias="$(alias_of "$script")"
engine="$(engine_of "$script")"
ctx="$(ctx_of "$script")"
gguf="$(flag "$script" -m)"
# Skip the precheck when -m is a shell variable (the script resolves the path
# itself, e.g. from a glob) or absent (Strata: paths live in its config); the
# launch script does its own existence check.
case "$gguf" in
  ""|*'$'*) : ;;
  *) [ -f "$gguf" ] || { echo "Model file not found (still downloading?): $gguf" >&2; exit 1; } ;;
esac

running="$(curl -fsS --max-time 2 "$HEALTH/v1/models" 2>/dev/null | jq -r '.data[0].id' || true)"
if [ "$running" = "$alias" ]; then
  echo "$alias is already running"
else
  pkill -x llama-server || true
  pkill -f "$STRATA_SERVER" || true  # SIGTERM: Strata's server stops its engine child
  while server_alive ik_llama.cpp || server_alive strata || pgrep -x strata >/dev/null; do sleep 0.5; done
  "./$script"
  echo "Loading $alias..."
  # llama-server answers 503 until loaded; Strata answers 200 with "loaded": false.
  until curl -fsS --max-time 2 "$HEALTH/health" 2>/dev/null | jq -e '.loaded != false' >/dev/null 2>&1; do
    server_alive "$engine" || { echo "$engine server died:" >&2; tail -20 "$LOG" >&2; exit 1; }
    sleep 1
  done
fi

[ -f .env ] || cp .env.example .env
set_env LOCAL_LLM_MODEL "$alias"
set_env LOCAL_LLM_CONTEXT_WINDOW "$ctx"
set_env PI_COMPACTION_KEEP_RECENT "$(( ctx / 4 ))"

# --wait: Pi's config is rendered during boot, so attaching earlier reads the old one.
docker compose up -d --wait
exec ./scripts/attach.sh
