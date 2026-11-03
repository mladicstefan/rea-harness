#!/usr/bin/env bash
# Pick a model, start its llama-server, point Pi at it and attach.
# Model name and context size are read from the models/*.sh scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=/home/djamla/llama-server.log
HEALTH=http://127.0.0.1:8080

flag() { sed -nE "s/.*[[:space:]]$2[[:space:]]+([^[:space:]]+).*/\1/p" "$1" | head -1; }
set_env() { sed -i -E "s|^$1=.*|$1=$2|" .env; }

scripts=(); labels=()
for f in models/*.sh; do
  [ "$f" = models/start.sh ] && continue
  scripts+=("$f")
  labels+=("$(flag "$f" --alias) ($(( $(flag "$f" -c) / 1024 ))k context)")
done

PS3="Model: "
script=""
select label in "${labels[@]}"; do
  if [ -n "${label:-}" ]; then script="${scripts[REPLY-1]}"; break; fi
done
[ -n "$script" ] || exit 1

alias="$(flag "$script" --alias)"
ctx="$(flag "$script" -c)"
gguf="$(flag "$script" -m)"
# Skip the precheck when -m is a shell variable (the script resolves the path
# itself, e.g. from a glob); the launch script does its own existence check.
case "$gguf" in
  *'$'*) : ;;
  *) [ -f "$gguf" ] || { echo "Model file not found (still downloading?): $gguf" >&2; exit 1; } ;;
esac

running="$(curl -fsS --max-time 2 "$HEALTH/v1/models" 2>/dev/null | jq -r '.data[0].id' || true)"
if [ "$running" = "$alias" ]; then
  echo "$alias is already running"
else
  pkill -x llama-server || true
  while pgrep -x llama-server >/dev/null; do sleep 0.5; done
  "./$script"
  echo "Loading $alias..."
  until curl -fsS --max-time 2 "$HEALTH/health" >/dev/null 2>&1; do
    pgrep -x llama-server >/dev/null || { echo "llama-server died:" >&2; tail -20 "$LOG" >&2; exit 1; }
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
