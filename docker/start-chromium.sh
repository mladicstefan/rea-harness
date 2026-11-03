#!/usr/bin/env bash
# Supervised headless Chromium exposing the DevTools protocol on loopback.
# Shared by chrome-devtools-mcp (--browserUrl) and REA's browser tools.
# --no-sandbox: Chrome's user-namespace sandbox cannot start inside Docker
# without extra privileges; the container runs as a non-root user instead.
set -u
CDP_PORT="${CDP_PORT:-9222}"
PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-/data/chromium}"
mkdir -p "$PROFILE_DIR"
while true; do
  # Locks on the volume name the previous container's hostname, which makes
  # Chromium refuse the profile after a recreate. Nothing else uses it here.
  rm -f "$PROFILE_DIR"/Singleton{Lock,Cookie,Socket}
  chromium \
    --headless \
    --no-sandbox \
    --disable-gpu \
    --disable-dev-shm-usage \
    --disable-background-networking \
    --disable-extensions \
    --no-first-run \
    --no-default-browser-check \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$CDP_PORT" \
    --user-data-dir="$PROFILE_DIR" \
    --window-size=1280,900 \
    ${CHROMIUM_EXTRA_ARGS:-} \
    about:blank >> /data/chromium.log 2>&1
  echo "[chromium] exited with $? ; restarting in 2s" >> /data/chromium.log
  sleep 2
done
