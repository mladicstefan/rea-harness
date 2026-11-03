#!/usr/bin/env bash
# Health check of a running harness: model endpoint, Chromium CDP, MCP servers, REA doctor.
cd "$(dirname "$0")/.."
docker compose exec -T agent bash -lc '
set -u
ok()   { printf "  [ok]   %s\n" "$*"; }
fail() { printf "  [FAIL] %s\n" "$*"; rc=1; }
rc=0
echo "== model endpoint"
if [ "${LLM_MODE:-generic}" = "llamacpp-router" ]; then url="${LLAMA_BASE_URL:-http://host.docker.internal:8080}/v1/models"; else url="${LOCAL_LLM_BASE_URL:-http://host.docker.internal:8080/v1}/models"; fi
if out=$(curl -fsS --max-time 5 -H "Authorization: Bearer ${LOCAL_LLM_API_KEY:-local}" "$url"); then
  ok "$url"; echo "$out" | jq -r ".data[]?.id" | sed "s/^/         model: /"
  if [ "${LLM_MODE:-generic}" != "llamacpp-router" ] && ! echo "$out" | jq -e --arg m "${LOCAL_LLM_MODEL:-}" ".data[]?|select(.id==\$m)" >/dev/null; then
    fail "LOCAL_LLM_MODEL=${LOCAL_LLM_MODEL:-} is not in the list above"
  fi
else fail "$url unreachable"; fi
echo "== chromium"
if v=$(curl -fsS --max-time 3 "http://127.0.0.1:${CDP_PORT:-9222}/json/version"); then ok "$(echo "$v" | jq -r .Browser)"; else fail "no CDP on ${CDP_PORT:-9222}"; fi
echo "== pi config"
for f in settings.json models.json mcp.json; do jq -e . "$PI_CODING_AGENT_DIR/$f" >/dev/null 2>&1 && ok "$f valid" || fail "$f invalid"; done
echo "== mcp servers (pi mcp list)"
if list=$(cd /workspace && timeout 120 pi mcp list --json 2>/dev/null); then
  echo "$list" | jq -r ".servers[] | \"  [\(.state)] \(.name) exposure=\(.exposure) tools=\(.tools|length)\""
  echo "$list" | jq -e "[.servers[]|select(.state!=\"connected\")]|length==0" >/dev/null || fail "an MCP server is not connected"
else fail "pi mcp list failed"; fi
echo "== rea doctor"
rea doctor --client pi --json 2>/dev/null | jq -r "\"  healthy=\(.healthy) registrations=\([.identity.registrations[]?|select(.client==\"pi\")|.state]|join(\",\")) skill=\(.identity.skill.state)\"" || fail "rea doctor failed"
echo "== skills visible to pi"
ls -d /data/home/.agents/skills/*/ /data/pi/git/github.com/obra/superpowers/skills/*/ 2>/dev/null | wc -l | sed "s/^/  skill dirs: /"
exit $rc
'
