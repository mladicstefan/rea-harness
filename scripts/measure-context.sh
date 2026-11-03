#!/usr/bin/env bash
# Measure the fixed per-turn context cost: one trivial non-interactive turn,
# reporting the input token count the model server billed for it.
# Usage: ./scripts/measure-context.sh            (current .env settings)
#        PI_CODEMODE_MODE=only ./scripts/measure-context.sh   (override for this run)
cd "$(dirname "$0")/.."
docker compose exec -T \
  ${PI_MCP_EXPOSURE:+-e PI_MCP_EXPOSURE="$PI_MCP_EXPOSURE"} \
  ${PI_CODEMODE_MODE:+-e PI_CODEMODE_MODE="$PI_CODEMODE_MODE"} \
  ${PI_CODEMODE_INLINE_BUDGET:+-e PI_CODEMODE_INLINE_BUDGET="$PI_CODEMODE_INLINE_BUDGET"} \
  ${CHROME_SLIM:+-e CHROME_SLIM="$CHROME_SLIM"} \
  agent bash -lc '
set -euo pipefail
export PI_CODING_AGENT_DIR=/tmp/pi-measure
rm -rf "$PI_CODING_AGENT_DIR"; cp -a /data/pi "$PI_CODING_AGENT_DIR"
/docker/render-config.sh >/dev/null
cd /workspace
out=$(timeout 300 pi --print --no-session --mode json "Reply with the single word OK." 2>/tmp/measure.err || true)
usage=$(echo "$out" | jq -c "select(.type==\"message_end\" and .message.role==\"assistant\") | .message.usage" | head -1)
if [ -z "$usage" ]; then echo "no assistant message; stderr:"; tail -20 /tmp/measure.err; exit 1; fi
echo "first-turn usage (as billed by the server): $usage"
echo "$usage" | jq -r "\"input tokens: \(.input + (.cacheRead // 0))   of context window \(env.LOCAL_LLM_CONTEXT_WINDOW // \"?\")\""
rm -rf "$PI_CODING_AGENT_DIR"
'
