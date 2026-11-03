# Plan: Dockerised Pi coding harness with REA, Chrome DevTools MCP and Superpowers, for a local LLM in a 32k context window

Status: plan, not yet implemented. Written 2026-11-03.

## 1. Goal

One `docker compose up -d` gives a Debian container that:

- runs the **Pi coding agent** (`@earendil-works/pi-coding-agent`) as the harness,
- has **REA** (`rea-agents`, the reverse-engineering MCP server) registered for Pi,
- has **Chrome DevTools MCP** (`chrome-devtools-mcp`) driving a headless Chromium inside the container,
- has **obra/superpowers** skills installed as a Pi package,
- talks to **whatever local model server the host is running** (llama.cpp, vLLM, Ollama, LM Studio) over NAT bridge networking, configured purely through compose variables,
- keeps all agent state (sessions, packages, MCP config, REA evidence, Chromium profile) on a **persistent named volume**,
- is **attachable**: the container idles, and you open Pi's TUI with `docker compose exec`.

Hard constraint: Pi's system prompt + tool declarations + REA + Chrome DevTools + superpowers must fit comfortably inside a **32k context window**, leaving most of it for actual work.

## 2. Key research findings that shape the design

| Topic | Finding | Consequence |
|---|---|---|
| Pi MCP support | Pi has built-in MCP (`builtin:mcp`). Config lives in `~/.pi/agent/mcp.json` under `mcpServers`; stdio servers use `command`/`args`/`env`. | No third-party MCP extension needed. |
| Pi tool exposure | Each MCP server has an `exposure`: `codemode` (default, tools callable only from codemode scripts, **not declared to the model**), `deferred` (loaded on demand via `tool_search`), `direct`, `hidden`. Per-tool `toolExposure` overrides exist. | REA's ~90 tools and Chrome DevTools' 60 tools cost ~0 prompt tokens. |
| Pi codemode | `builtin:codemode` runs model-written JS in a QuickJS sandbox; the model discovers tools with `searchTools()`/`describeTool()`. `codemode.mode: "only"` hides even built-in tools behind the single `codemode` tool; `codemode.inlineBudget` (default 3000 est. tokens) caps inline declarations. | This **is** the Cloudflare "Code Mode" pattern, native to Pi. `@cloudflare/codemode` is not needed (its sandbox executor requires Cloudflare Workers anyway). |
| Pi local models | `models.json` supports `openai-completions` providers with `baseUrl`, `apiKey`, per-model `contextWindow` (default 128000!) and `maxTokens`. `builtin:llama.cpp` extension talks to a llama.cpp **router** (`llama serve` without `-m`) via `LLAMA_BASE_URL`. | Provide both: generic OpenAI-compatible provider rendered from env, plus optional llama.cpp router path. Must set `contextWindow: 32768` or compaction never fires. |
| Pi compaction | `compaction.reserveTokens` (default 16384) and `keepRecentTokens` (default 20000) are sized for 128k+ windows. | Must be lowered for 32k. |
| Pi config dir | `PI_CODING_AGENT_DIR` overrides `~/.pi/agent`; `PI_PACKAGE_DIR` overrides package dir. | Point both at the volume. |
| REA for Pi | `rea setup --client pi --yes --json` writes `mcpServers.rea` (stdio, absolute node + `rea.mjs mcp`) into Pi's `mcp.json` and a skill under `~/.agents/skills`. Needs Node 22.23.4+ / 24.22.1+. | Run setup at image build against a seed config dir, copy to volume on first boot. |
| REA tool scoping | `REA_MCP_TOOL_FAMILIES=<comma list>` restricts `tools/list` to families (`session`, `direct`, `firmware`, `browser`, `pcap`, `javascript-runtime`, `android`, `adb`, `apktool`, `frida`, `jeb`, `flutter`, `native`, `artifact`, `managed`, `electron`, `application`). REA's docs recommend `browser,electron,application,javascript-runtime,session` for web/Electron work. `REA_MCP_OUTPUT_SCHEMA_PROFILE=compact|off` shrinks schemas. | Make the family list a compose variable. Default to the web/Electron set, which needs **no native engine** (Ghidra/Hopper only needed for `native`). |
| REA browser tools | REA's browser family takes a loopback CDP endpoint. | Run one shared headless Chromium with `--remote-debugging-port=9222` and point both REA and Chrome DevTools MCP at it. |
| Chrome DevTools MCP | 60 tools, 11 categories (5 off by default); `--slim` = 3 tools; `--browserUrl http://127.0.0.1:9222` attaches to a running Chrome; `--headless`, `--isolated`, `--executablePath`, `--chromeArg` exist. Chrome's own sandbox cannot start inside Docker without extra privileges. | Attach to the shared Chromium (launched with `--no-sandbox` as a non-root user) instead of letting the MCP launch its own. |
| Superpowers | Official Pi support: `pi install git:github.com/obra/superpowers`. Adds skills plus a small extension that injects the `using-superpowers` bootstrap at session start and after compaction. | Install at build into the seed dir. The bootstrap injection is the one superpowers cost that lands in context every session; measure it. |

Sources: Pi docs (`packages/coding-agent/docs/mcp.md`, `codemode.md`, `settings.md`, `models-configuration.md`, `llama-cpp.md`, `cli.md`, `environment-variables.md` in github.com/earendil-works/pi), REA docs (`docs/installation.md`, `docs/client-configuration.md#pi`, `docs/mcp-contracts.md#tool-family-advertising-scope` in github.com/morluto/rea), Chrome DevTools MCP docs (`docs/configuration.md`, `docs/tool-reference.md`), github.com/obra/superpowers README, github.com/cloudflare/agents `packages/codemode` README.

## 3. Context budget (the 32k constraint)

Target: fixed per-turn overhead ≤ 8k tokens, leaving ≥ 24k for conversation + tool output.

| Item | Strategy | Estimated tokens |
|---|---|---|
| Pi system prompt + AGENTS.md | Keep AGENTS.md short; optionally trim via `SYSTEM.md` | ~1.5–2.5k |
| Built-in tools (`read`, `bash`, `edit`, `write`) | Keep as `direct` (they are small) | ~1.5k |
| `codemode` tool description | `codemode.inlineBudget: 1500` | ≤1.5k |
| `tool_search` tool | Keep; tiny | ~0.2k |
| REA (≈90 tools) | `exposure: "codemode"` + `REA_MCP_TOOL_FAMILIES` + `REA_MCP_OUTPUT_SCHEMA_PROFILE=off` | ~0.1k (one summary line) |
| Chrome DevTools (60 tools) | `exposure: "codemode"` | ~0.1k |
| Superpowers bootstrap (`using-superpowers`) | Measure; if >2k, replace with a trimmed `APPEND_SYSTEM.md` pointer and load skills on demand | ~1–2k |
| **Fixed total** | | **~6–8k** |
| Compaction | `compaction.reserveTokens: 6144`, `keepRecentTokens: 8192`, `contextWindow: 32768` in `models.json` | leaves ~18–20k working room |

Escalation ladder if measurements come in high:

1. Default: MCP servers `codemode`, built-ins `direct`, `codemode.mode: "on"`.
2. `codemode.mode: "only"`: everything behind one `codemode` tool (single-tool prompt, Cloudflare-style). Lower `inlineBudget` to 1000.
3. Chrome DevTools `--slim` (3 tools) and `--category*` flags off, in case the summary lines or tool_search results get long.
4. Drop the superpowers bootstrap extension (keep the skills; load via `/skill:...` commands or `tool_search`).

Note on small local models: `codemode` requires the model to write JavaScript against a discovered API. 7–14B coder models handle this; weaker models may do better with `exposure: "deferred"` + `tool_search` (classic tool calls, loaded on demand). Expose that as a compose variable too (`PI_MCP_EXPOSURE=codemode|deferred`).

## 4. Target repository layout

```
rea-harness/
├── docker-compose.yml
├── .env.example                 # every tunable, documented
├── Dockerfile
├── docker/
│   ├── entrypoint.sh            # seed volume, render configs, start chromium, idle
│   ├── render-config.sh         # envsubst models.json / settings.json / mcp.json
│   ├── start-chromium.sh        # headless chromium on 127.0.0.1:9222
│   └── seed/                    # baked at build time, copied to volume on first boot
│       └── pi/
│           ├── settings.json.tmpl
│           ├── models.json.tmpl
│           ├── mcp.json.tmpl
│           └── APPEND_SYSTEM.md
├── scripts/
│   ├── attach.sh                # docker compose exec -it agent pi
│   ├── measure-context.sh       # one-turn --mode json run, prints prompt tokens
│   └── smoke.sh                 # checks model endpoint, CDP, REA doctor, pi auth
├── workspace/                   # bind-mounted project dir (gitignored)
└── docs/plans/…
```

## 5. Component design

### 5.1 Base image (`Dockerfile`)

- `FROM debian:trixie-slim` (Debian 13). Install: `ca-certificates curl git gnupg procps jq gettext-base tmux xz-utils` plus `chromium chromium-sandbox fonts-liberation fonts-noto-color-emoji` (Debian's Chromium builds for amd64 and arm64; Google Chrome `.deb` is amd64-only). `procps` is required by REA on Linux.
- Node **24.x** from NodeSource (satisfies REA's `>=24.22.1` floor; verify the exact floor at build time with `rea doctor`).
- Create non-root user `agent` (uid 1000), `HOME=/home/agent`.
- Global npm installs, **pinned** (`ARG` per package so bumps are explicit):
  - `@earendil-works/pi-coding-agent@<pin>` (installed with `--ignore-scripts` as the README recommends for npm installs)
  - `rea-agents@<pin>` (6.x; Pi client support exists from 6.4.0)
  - `chrome-devtools-mcp@<pin>`
- Build-time seeding (as `agent`, with `PI_CODING_AGENT_DIR=/opt/seed/pi` and `HOME=/opt/seed/home`):
  - `pi install git:github.com/obra/superpowers` (pin to a commit via `#<sha>` if Pi's git source supports it; otherwise record the sha in a label).
  - `rea setup --client pi --yes --json` → writes `mcpServers.rea` into the seed `mcp.json` and the REA skill into `/opt/seed/home/.agents/skills`.
  - Post-process the seed `mcp.json` with `jq`: add the `chrome-devtools` server, set `exposure` placeholders, and add `env` placeholders for REA. Keep the absolute node path REA wrote.
- Optional heavy layer behind `ARG WITH_GHIDRA=0`: Temurin JDK 21 + Ghidra, `GHIDRA_INSTALL_DIR`, needed only for the `native` family. Off by default (adds >1 GB).
- `ENV PI_CODING_AGENT_DIR=/data/pi PI_PACKAGE_DIR=/data/pi/packages PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0 CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS=1 CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1 TERM=xterm-256color COLORTERM=truecolor`
- `ENTRYPOINT ["/docker/entrypoint.sh"]`, `WORKDIR /workspace`.

### 5.2 Persistent state (`/data` named volume)

```
/data/pi/                 PI_CODING_AGENT_DIR: settings.json, models.json, mcp.json, auth.json,
                          sessions/, packages/ (superpowers), skills/, extensions/
/data/home/.agents/skills REA skill (symlinked from /home/agent/.agents)
/data/chromium/           Chromium user-data-dir (persistent cookies/logins for the browser tools)
/data/rea/                REA evidence bundles / Ghidra projects (REA_GHIDRA_PROJECT_PATH)
/data/npm-cache/
```

Entrypoint seeds `/data/pi` from `/opt/seed/pi` only if `/data/pi/.seeded` is absent, then **re-renders** the three `*.tmpl` files every boot from env (so changing `.env` and restarting is enough). Templates are rendered to real files; user edits to the rendered files are overwritten on boot, which is documented. `settings.json` user edits that must survive go into `/data/pi/settings.local.json`, merged with `jq -s '.[0] * .[1]'`.

### 5.3 Model provider configuration (compose variables)

`.env.example`:

```
# --- Which local server to use -------------------------------------------
# generic: any OpenAI-compatible /v1 endpoint (llama-server -m ..., vLLM, Ollama, LM Studio)
# llamacpp-router: llama.cpp router mode (llama serve without -m), uses Pi's builtin:llama.cpp
LLM_MODE=generic

# generic mode
LOCAL_LLM_BASE_URL=http://host.docker.internal:8080/v1
LOCAL_LLM_API_KEY=local
LOCAL_LLM_MODEL=qwen2.5-coder-14b-instruct      # the id the server reports in /v1/models
LOCAL_LLM_CONTEXT_WINDOW=32768
LOCAL_LLM_MAX_TOKENS=4096
LOCAL_LLM_REASONING=false                       # true for thinking models
LOCAL_LLM_THINKING_FORMAT=openai                # openai | qwen | deepseek | chat-template ...
LOCAL_LLM_MAX_TOKENS_FIELD=max_tokens           # llama.cpp/vLLM want max_tokens

# llamacpp-router mode
LLAMA_BASE_URL=http://host.docker.internal:8080
LLAMA_API_KEY=

# --- Context budget -------------------------------------------------------
PI_MCP_EXPOSURE=codemode        # codemode | deferred
PI_CODEMODE_MODE=on             # on | only
PI_CODEMODE_INLINE_BUDGET=1500
PI_COMPACTION_RESERVE=6144
PI_COMPACTION_KEEP_RECENT=8192
PI_THINKING=off

# --- REA ------------------------------------------------------------------
REA_TOOL_FAMILIES=browser,electron,application,javascript-runtime,session
REA_OUTPUT_SCHEMA_PROFILE=off   # complete | compact | off
REA_INPUT_SCHEMA_PROFILE=compact
REA_MAX_RESPONSE_BYTES=65536    # keep tool results small for a 32k window
REA_LOG_LEVEL=info

# --- Chrome DevTools MCP --------------------------------------------------
CHROME_SLIM=0                   # 1 => --slim (3 tools)
CDP_PORT=9222

# --- Host paths -----------------------------------------------------------
WORKSPACE=./workspace
```

Rendered `models.json.tmpl` (generic mode):

```json
{
  "$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "local": {
      "name": "Local",
      "baseUrl": "${LOCAL_LLM_BASE_URL}",
      "api": "openai-completions",
      "apiKey": "${LOCAL_LLM_API_KEY}",
      "models": [
        {
          "id": "${LOCAL_LLM_MODEL}",
          "contextWindow": ${LOCAL_LLM_CONTEXT_WINDOW},
          "maxTokens": ${LOCAL_LLM_MAX_TOKENS},
          "reasoning": ${LOCAL_LLM_REASONING},
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "compat": {
            "maxTokensField": "${LOCAL_LLM_MAX_TOKENS_FIELD}",
            "thinkingFormat": "${LOCAL_LLM_THINKING_FORMAT}",
            "supportsStore": false,
            "supportsDeveloperRole": false
          }
        }
      ]
    }
  }
}
```

Rendered `settings.json.tmpl`:

```json
{
  "defaultProvider": "local",
  "defaultModel": "${LOCAL_LLM_MODEL}",
  "defaultTools": ["read", "bash", "edit", "write"],
  "compaction": {
    "enabled": true,
    "reserveTokens": ${PI_COMPACTION_RESERVE},
    "keepRecentTokens": ${PI_COMPACTION_KEEP_RECENT}
  },
  "codemode": { "mode": "${PI_CODEMODE_MODE}", "inlineBudget": ${PI_CODEMODE_INLINE_BUDGET} },
  "packages": ["git:github.com/obra/superpowers"],
  "sessionDir": "/data/pi/sessions"
}
```

In `llamacpp-router` mode the entrypoint omits the `local` provider, exports `LLAMA_BASE_URL`/`LLAMA_API_KEY`, and sets `defaultProvider` to `llama.cpp`. (Pi's builtin extension discovers router models; a single-model `llama-server -m …` must use generic mode. The host should start llama.cpp with `-c 32768` and, in router mode, `--no-models-autoload` as Pi's docs show.)

Rendered `mcp.json.tmpl` (REA's `command`/`args` come from what `rea setup` wrote at build time; jq splices env/exposure in):

```json
{
  "mcpServers": {
    "rea": {
      "type": "stdio",
      "command": "/usr/bin/node",
      "args": ["/usr/lib/node_modules/rea-agents/scripts/rea.mjs", "mcp"],
      "exposure": "${PI_MCP_EXPOSURE}",
      "description": "Reverse engineering: web/Electron bundles, JS runtime, CDP browser targets, evidence ledger",
      "env": {
        "REA_MCP_TOOL_FAMILIES": "${REA_TOOL_FAMILIES}",
        "REA_MCP_INPUT_SCHEMA_PROFILE": "${REA_INPUT_SCHEMA_PROFILE}",
        "REA_MCP_OUTPUT_SCHEMA_PROFILE": "${REA_OUTPUT_SCHEMA_PROFILE}",
        "REA_MCP_MAX_RESPONSE_BYTES": "${REA_MAX_RESPONSE_BYTES}",
        "REA_LOG_LEVEL": "${REA_LOG_LEVEL}"
      }
    },
    "chrome-devtools": {
      "command": "chrome-devtools-mcp",
      "args": ["--browserUrl", "http://127.0.0.1:${CDP_PORT}", "--no-usage-statistics"],
      "exposure": "${PI_MCP_EXPOSURE}",
      "description": "Headless Chromium: navigate, click, evaluate JS, screenshots, network/console/perf"
    }
  }
}
```

`CHROME_SLIM=1` appends `--slim`. The REA `description` field is what the model sees in the system prompt summary when tools are `codemode`/`deferred`, so keep it to one line.

### 5.4 Shared headless Chromium

`start-chromium.sh` (run by entrypoint under `tmux`/`setsid`, restarted if it dies):

```
chromium --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=${CDP_PORT} \
  --user-data-dir=/data/chromium --no-first-run --no-default-browser-check about:blank
```

- `--no-sandbox` is required because Docker blocks Chrome's user namespace sandbox; mitigate with non-root user, `security_opt: no-new-privileges`, and keeping port 9222 bound to loopback (not published). Document the alternative (`seccomp` profile from Playwright/Jess Frazelle + `cap_add: SYS_ADMIN`) for people who want the sandbox back.
- `shm_size: 1gb` in compose (Chromium crashes with the 64 MB default).
- Both REA's browser family (loopback CDP endpoint) and chrome-devtools-mcp (`--browserUrl`) attach to this one instance, so page state is shared between the two tool sets.

### 5.5 Superpowers

- Installed at build into the seed via `pi install git:github.com/obra/superpowers`; `packages` entry in settings keeps it declared.
- Its extension injects `using-superpowers` at session start and after each compaction. Measure its size (step 7). If it is too large for 32k, keep the skills but exclude the extension: `"packages": [{ "source": "git:github.com/obra/superpowers", "extensions": [] }]` (verify the exact package-filter syntax in Pi's `packages.md`), and add a two-line `APPEND_SYSTEM.md` telling the model to run `/skill:brainstorming`, `/skill:writing-plans` etc.
- REA's bundled skill (installed under `~/.agents/skills`) is also picked up; include `/data/home/.agents/skills` in `settings.json` `skills` array if Pi doesn't scan `~/.agents` on its own.

### 5.6 `docker-compose.yml`

```yaml
services:
  agent:
    build:
      context: .
      args:
        WITH_GHIDRA: ${WITH_GHIDRA:-0}
    image: rea-harness:local
    container_name: rea-harness
    env_file: .env
    environment:
      PI_CODING_AGENT_DIR: /data/pi
      PI_PACKAGE_DIR: /data/pi/packages
      TERM: xterm-256color
      COLORTERM: truecolor
    volumes:
      - harness-data:/data
      - ${WORKSPACE:-./workspace}:/workspace
    working_dir: /workspace
    extra_hosts:
      - "host.docker.internal:host-gateway"   # reach the host's llama.cpp from NAT bridge
    networks: [harness]
    stdin_open: true
    tty: true
    init: true
    shm_size: "1gb"
    security_opt: [no-new-privileges:true]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:${CDP_PORT:-9222}/json/version"]
      interval: 30s
      timeout: 5s
      retries: 3

  # Optional: run llama.cpp inside the same compose network instead of on the host.
  # docker compose --profile llm up -d ; set LOCAL_LLM_BASE_URL=http://llm:8080/v1
  llm:
    profiles: [llm]
    image: ghcr.io/ggml-org/llama.cpp:server          # or :server-cuda / :server-vulkan
    command: >
      -m /models/${LLM_GGUF} -c ${LOCAL_LLM_CONTEXT_WINDOW:-32768} -ngl ${LLM_NGL:-99}
      --host 0.0.0.0 --port 8080 --jinja
    volumes:
      - ${MODELS_DIR:-./models}:/models:ro
    networks: [harness]
    # deploy.resources.reservations.devices for NVIDIA, documented in README

networks:
  harness:
    driver: bridge          # default NAT; nothing is published to the host

volumes:
  harness-data:
```

Attach: `scripts/attach.sh` = `docker compose exec -it agent pi "$@"`. `docker attach rea-harness` also works since the entrypoint keeps a `tmux` session as PID 1's child; `exec` is recommended because detaching from `attach` needs `Ctrl-p Ctrl-q`.

### 5.7 Entrypoint sequence

1. Seed `/data` on first boot (copy `/opt/seed`, `chown agent`, touch `.seeded`).
2. `render-config.sh`: `envsubst` the three templates → `/data/pi/*.json`, validate with `jq empty` (Pi and REA reject non-strict JSON), merge `settings.local.json` if present.
3. Symlink `/home/agent/.agents` → `/data/home/.agents`.
4. Start Chromium (background, supervised loop).
5. Wait for CDP `/json/version` (10 s timeout; warn, don't fail).
6. Probe the model endpoint (`/v1/models` or router `/models`); print a clear warning naming the URL if unreachable.
7. Optionally `rea doctor --client pi --json` (summarised to one line).
8. `exec tmux new-session -d -s harness` then `exec sleep infinity` / `tail -f /dev/null` so the container stays up for `exec`.

## 6. Implementation tasks

1. **Scaffold** `.gitignore` (`workspace/`, `models/`, `.env`), `.env.example`, `README.md` (usage, attach, variables, NAT note, Chrome sandbox trade-off).
2. **Dockerfile** per 5.1. Verify at build that `rea setup --client pi --dry-run --json` picks the seed dir via `PI_CODING_AGENT_DIR`.
3. **Seed templates + jq post-processing** per 5.3. Verify REA's written `command`/`args` are absolute and survive the template.
4. **Entrypoint, chromium supervisor, render script** per 5.4/5.7.
5. **docker-compose.yml** per 5.6, plus the optional `llm` profile.
6. **Scripts**: `attach.sh`, `smoke.sh` (endpoint reachable, CDP up, `rea doctor` ok, `pi auth check`, MCP servers connected via `pi --print "/mcp"` or JSON mode), `measure-context.sh`.
7. **Measure** (see 7). Record numbers in the README and tune `.env` defaults.
8. **Optional**: `WITH_GHIDRA=1` build path and `native,artifact,session` family preset.

## 7. Verification

- `docker compose build && docker compose up -d && ./scripts/smoke.sh` → all green.
- `./scripts/measure-context.sh`: runs `pi --print --no-session --model local/… "reply with OK"` in `--mode json`, extracts prompt token usage from the first assistant event. Pass criterion: **≤ 8,000 prompt tokens** on the first turn with REA + Chrome DevTools + superpowers loaded. Repeat with `PI_CODEMODE_MODE=only` and with `PI_MCP_EXPOSURE=deferred` and record all three.
- Functional: inside Pi, ask it to "open https://example.com in the browser and list the page's console errors" (Chrome DevTools via codemode) and "analyze the JavaScript application at /workspace/sample" (REA `analyze_javascript_application`). Both must succeed without a native engine.
- Persistence: `docker compose down && up -d` → previous session visible via `/resume`, superpowers still installed, Chromium profile retained.
- NAT: model endpoint reached via `host.docker.internal` from inside the container; no ports published on the host.
- Compaction: run a long task and confirm compaction triggers before the 32k limit (watch for context-length errors from the server; llama.cpp returns HTTP 400 when exceeded).

## 8. Risks and open points

- **REA npm version floor** is unusually specific (Node `>=22.23.4` / `>=24.22.1`); pin the Node minor in the Dockerfile and re-check with `rea doctor` on every bump.
- **Superpowers bootstrap size** is unmeasured; it is the most likely thing to blow the budget. Fallback in 5.5.
- **Small-model codemode competence**: if the local model cannot write working codemode scripts, switch `PI_MCP_EXPOSURE=deferred` (tool_search + classic tool calls).
- **`pi install git:` pinning**: confirm whether Pi supports a `#sha` suffix; otherwise pin by vendoring a submodule and using a local package path.
- **Chrome without sandbox** in the container: acceptable for a local RE lab, documented, with the seccomp alternative.
- **GPU inside compose** (only if the `llm` profile is used): NVIDIA container toolkit / ROCm / Vulkan variants are host-specific; leave as documented snippets rather than defaults.
- The `superpowers:planning` skill was not available in this session, so this plan follows its structure (goal, research, design, tasks, verification) by hand.
