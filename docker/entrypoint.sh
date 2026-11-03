#!/usr/bin/env bash
set -euo pipefail

DATA=/data
AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/pi}"
CDP_PORT="${CDP_PORT:-9222}"

log() { echo "[entrypoint] $*"; }

# 1. Seed the persistent volume on first boot.
if [ ! -f "$DATA/.seeded" ]; then
  log "first boot: seeding $DATA from /opt/seed"
  mkdir -p "$AGENT_DIR" "$DATA/home" "$DATA/rea/ghidra" "$DATA/chromium" "$DATA/pi/sessions"
  cp -a /opt/seed/pi/. "$AGENT_DIR/"
  cp -a /opt/seed/home/. "$DATA/home/"
  date -u +%FT%TZ > "$DATA/.seeded"
fi
mkdir -p "$DATA/home/.agents" "$DATA/pi/sessions" "$DATA/rea" "$DATA/chromium"

# REA installs its skill under ~/.agents; keep that on the volume.
if [ ! -e "$HOME/.agents" ]; then
  ln -s "$DATA/home/.agents" "$HOME/.agents"
fi

# 2. Render Pi config from the environment (every boot).
/docker/render-config.sh

# 3. Shared headless Chromium.
/docker/start-chromium.sh &
for _ in $(seq 1 20); do
  if curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1; then
    log "chromium: CDP ready on 127.0.0.1:${CDP_PORT}"
    break
  fi
  sleep 0.5
done
curl -fsS "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null 2>&1 \
  || log "WARNING: chromium did not come up; see $DATA/chromium.log"

# 4. Probe the model endpoint (informational only).
if [ "${LLM_MODE:-generic}" = "llamacpp-router" ]; then
  probe="${LLAMA_BASE_URL:-http://host.docker.internal:8080}/v1/models"
else
  probe="${LOCAL_LLM_BASE_URL:-http://host.docker.internal:8080/v1}/models"
fi
if curl -fsS --max-time 5 -H "Authorization: Bearer ${LOCAL_LLM_API_KEY:-local}" "$probe" >/dev/null 2>&1; then
  log "model endpoint reachable: $probe"
else
  log "WARNING: model endpoint not reachable at $probe (is the server listening on 0.0.0.0, or the docker bridge address?)"
fi

log "ready. attach with: docker compose exec -it agent /docker/pi.sh   (or ./scripts/attach.sh)"

# 5. Stay up. With tty+stdin_open this is an interactive shell for `docker attach`;
#    `docker compose exec` works regardless.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi
exec bash -il
