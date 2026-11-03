#!/usr/bin/env bash
# Render Pi's settings.json / models.json / mcp.json into $PI_CODING_AGENT_DIR
# from the container environment. Runs on every boot, so editing .env and
# restarting the container is enough to reconfigure the harness.
set -euo pipefail

AGENT_DIR="${PI_CODING_AGENT_DIR:-/data/pi}"
TMPL_DIR="${TMPL_DIR:-/docker/seed/pi}"

# Defaults (mirrors .env.example); compose/.env override them.
: "${LLM_MODE:=generic}"
: "${LOCAL_LLM_BASE_URL:=http://host.docker.internal:8080/v1}"
: "${LOCAL_LLM_API_KEY:=local}"
: "${LOCAL_LLM_MODEL:=local-model}"
: "${LOCAL_LLM_CONTEXT_WINDOW:=32768}"
: "${LOCAL_LLM_MAX_TOKENS:=4096}"
: "${LOCAL_LLM_REASONING:=false}"
: "${LOCAL_LLM_THINKING_FORMAT:=openai}"
: "${LOCAL_LLM_MAX_TOKENS_FIELD:=max_tokens}"
: "${PI_MCP_EXPOSURE:=codemode}"
: "${PI_CODEMODE_MODE:=on}"
: "${PI_CODEMODE_INLINE_BUDGET:=1500}"
: "${PI_COMPACTION_RESERVE:=6144}"
: "${PI_COMPACTION_KEEP_RECENT:=8192}"
: "${REA_TOOL_FAMILIES:=browser,electron,application,javascript-runtime,session}"
: "${REA_INPUT_SCHEMA_PROFILE:=compact}"
: "${REA_OUTPUT_SCHEMA_PROFILE:=off}"
: "${REA_MAX_RESPONSE_BYTES:=65536}"
: "${REA_LOG_LEVEL:=info}"
: "${CHROME_SLIM:=0}"
: "${CDP_PORT:=9222}"
: "${SUPERPOWERS_REF:=main}"
export LLM_MODE LOCAL_LLM_BASE_URL LOCAL_LLM_API_KEY LOCAL_LLM_MODEL LOCAL_LLM_CONTEXT_WINDOW \
  LOCAL_LLM_MAX_TOKENS LOCAL_LLM_REASONING LOCAL_LLM_THINKING_FORMAT LOCAL_LLM_MAX_TOKENS_FIELD \
  PI_MCP_EXPOSURE PI_CODEMODE_MODE PI_CODEMODE_INLINE_BUDGET PI_COMPACTION_RESERVE \
  PI_COMPACTION_KEEP_RECENT REA_TOOL_FAMILIES REA_INPUT_SCHEMA_PROFILE REA_OUTPUT_SCHEMA_PROFILE \
  REA_MAX_RESPONSE_BYTES REA_LOG_LEVEL CHROME_SLIM CDP_PORT SUPERPOWERS_REF

# Only substitute the variables we own, so any other ${...} in a template is
# left for Pi's own interpolation.
VARS='$LOCAL_LLM_BASE_URL $LOCAL_LLM_API_KEY $LOCAL_LLM_MODEL $LOCAL_LLM_CONTEXT_WINDOW $LOCAL_LLM_MAX_TOKENS $LOCAL_LLM_REASONING $LOCAL_LLM_THINKING_FORMAT $LOCAL_LLM_MAX_TOKENS_FIELD $PI_MCP_EXPOSURE $PI_CODEMODE_MODE $PI_CODEMODE_INLINE_BUDGET $PI_COMPACTION_RESERVE $PI_COMPACTION_KEEP_RECENT $REA_TOOL_FAMILIES $REA_INPUT_SCHEMA_PROFILE $REA_OUTPUT_SCHEMA_PROFILE $REA_MAX_RESPONSE_BYTES $REA_LOG_LEVEL $CDP_PORT $SUPERPOWERS_REF'

render() { # render <template> <output> [jq filter]
  local tmpl="$1" out="$2" filter="${3:-.}" tmp
  tmp="$(mktemp)"
  envsubst "$VARS" < "$tmpl" | jq "$filter" > "$tmp"   # jq also validates strict JSON
  mv "$tmp" "$out"
}

mkdir -p "$AGENT_DIR"

# --- settings.json ---------------------------------------------------------
settings_filter='.'
if [ "$LLM_MODE" = "llamacpp-router" ]; then
  # Pi's builtin llama.cpp extension discovers models from the router; pick one with /model.
  settings_filter='del(.defaultProvider, .defaultModel)'
else
  # Generic OpenAI-compatible endpoint: keep the llama.cpp router extension out of the way.
  settings_filter='. + {extensions: ["-builtin:llama.cpp"]}'
fi
if [ -f "$AGENT_DIR/settings.local.json" ]; then
  # User overrides survive re-rendering: settings.local.json is merged on top.
  tmp="$(mktemp)"
  envsubst "$VARS" < "$TMPL_DIR/settings.json.tmpl" | jq "$settings_filter" \
    | jq -s '.[0] * .[1]' /dev/stdin "$AGENT_DIR/settings.local.json" > "$tmp"
  mv "$tmp" "$AGENT_DIR/settings.json"
else
  render "$TMPL_DIR/settings.json.tmpl" "$AGENT_DIR/settings.json" "$settings_filter"
fi

# --- models.json -----------------------------------------------------------
if [ "$LLM_MODE" = "llamacpp-router" ]; then
  printf '{\n  "providers": {}\n}\n' > "$AGENT_DIR/models.json"
else
  render "$TMPL_DIR/models.json.tmpl" "$AGENT_DIR/models.json"
fi

# --- mcp.json --------------------------------------------------------------
mcp_filter='.'
if [ "$CHROME_SLIM" = "1" ]; then
  mcp_filter='.mcpServers["chrome-devtools"].args += ["--slim"]'
fi
if [ -f "$AGENT_DIR/mcp.local.json" ]; then
  tmp="$(mktemp)"
  envsubst "$VARS" < "$TMPL_DIR/mcp.json.tmpl" | jq "$mcp_filter" \
    | jq -s '.[0] * .[1]' /dev/stdin "$AGENT_DIR/mcp.local.json" > "$tmp"
  mv "$tmp" "$AGENT_DIR/mcp.json"
else
  render "$TMPL_DIR/mcp.json.tmpl" "$AGENT_DIR/mcp.json" "$mcp_filter"
fi

echo "[render-config] mode=$LLM_MODE model=$LOCAL_LLM_MODEL endpoint=$LOCAL_LLM_BASE_URL ctx=$LOCAL_LLM_CONTEXT_WINDOW mcp-exposure=$PI_MCP_EXPOSURE codemode=$PI_CODEMODE_MODE"
