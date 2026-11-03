# rea-harness

A Docker container that runs the [Pi coding agent](https://github.com/earendil-works/pi) with
[REA](https://github.com/morluto/rea) (reverse-engineering MCP), the
[Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) on a shared headless
Chromium, and [obra/superpowers](https://github.com/obra/superpowers) skills, against a **local LLM
served from the host** (llama.cpp, vLLM, Ollama, LM Studio). Tuned so everything fits a **32k context
window**.

```
host GPU ── llama-server / vLLM / Ollama  (0.0.0.0:8080)
                 ▲  NAT bridge, host.docker.internal
                 │
┌────────────────┴──────────── rea-harness container (Debian 13) ─────────────┐
│  pi (TUI)  ──codemode──▶  rea mcp (229 tools)  ─┐                           │
│            ──codemode──▶  chrome-devtools-mcp ──┴─▶ headless chromium :9222 │
│  superpowers skills · REA skill · /data volume · /workspace bind mount      │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Quick start

```bash
cp .env.example .env            # set LOCAL_LLM_MODEL and LOCAL_LLM_BASE_URL
docker compose build
docker compose up -d
./scripts/smoke.sh              # endpoint, chromium, MCP servers, rea doctor
./scripts/attach.sh             # opens Pi's TUI (docker compose exec -it agent /docker/pi.sh)
```

The model server must listen on an address the container can reach, for example:

```bash
llama-server -m model.gguf -c 32768 -ngl 99 --host 0.0.0.0 --port 8080 --jinja
```

`host.docker.internal` is mapped to the host gateway by compose (`extra_hosts`), so the default
`LOCAL_LLM_BASE_URL=http://host.docker.internal:8080/v1` works on Linux, macOS and Windows.
No container port is published; the Chromium DevTools port stays on the container's loopback.

## Attaching

- `./scripts/attach.sh [pi args]` starts Pi in `/workspace` (`--continue`, `-p "prompt"`, ... pass through).
- `./scripts/shell.sh` gives a bash shell in the container.
- `docker attach rea-harness` also works: PID 1's child is an interactive bash on the container tty.
  Detach with `Ctrl-p Ctrl-q` (Ctrl-D would stop the container; it restarts automatically).

Put projects under `./workspace` on the host (`WORKSPACE` in `.env`). Files are owned by uid 1000.

## Persistent state (`harness-data` volume, mounted at `/data`)

| Path | Contents |
|---|---|
| `/data/pi` | Pi agent dir: `settings.json`, `models.json`, `mcp.json`, `auth.json`, `sessions/`, `git/` (superpowers package) |
| `/data/home/.agents/skills` | REA's `reverse-engineer-anything` skill (symlinked from `~/.agents`) |
| `/data/chromium` | Chromium profile (cookies/logins survive restarts) |
| `/data/rea` | REA evidence / Ghidra projects |

`settings.json`, `models.json` and `mcp.json` are **re-rendered from the environment on every boot**
by `docker/render-config.sh`. To keep manual overrides, put them in `/data/pi/settings.local.json` or
`/data/pi/mcp.local.json`; they are deep-merged on top of the rendered files.

## Configuration (`.env`)

| Variable | Default | Meaning |
|---|---|---|
| `LLM_MODE` | `generic` | `generic` = any OpenAI-compatible `/v1`; `llamacpp-router` = llama.cpp router mode via Pi's builtin integration (pick model with `/model`) |
| `LOCAL_LLM_BASE_URL` | `http://host.docker.internal:8080/v1` | endpoint |
| `LOCAL_LLM_MODEL` | | model id as listed by `/v1/models` |
| `LOCAL_LLM_CONTEXT_WINDOW` | `32768` | must match the server (`-c`); drives Pi's compaction |
| `LOCAL_LLM_MAX_TOKENS` | `4096` | max completion tokens |
| `LOCAL_LLM_REASONING` / `LOCAL_LLM_THINKING_FORMAT` | `false` / `openai` | thinking models (`qwen`, `deepseek`, ...) |
| `PI_MCP_EXPOSURE` | `codemode` | `codemode` keeps all MCP tools out of the prompt; `deferred` loads them on demand through `tool_search` |
| `PI_CODEMODE_MODE` | `on` | `only` hides built-in tools behind the single `codemode` tool too |
| `PI_COMPACTION_RESERVE` / `PI_COMPACTION_KEEP_RECENT` | `6144` / `8192` | compaction thresholds sized for 32k |
| `REA_TOOL_FAMILIES` | `browser,electron,application,javascript-runtime,session` | REA family scope (`native,artifact,...` need Ghidra/Hopper) |
| `CHROME_SLIM` | `0` | `1` = Chrome DevTools MCP exposes only 3 tools |
| `PI_THINKING` | `off` | thinking level passed to `pi` by `attach.sh` |

Changing `.env` and running `docker compose up -d` (recreate) applies the new values.

## Context budget

Pi declares only its built-in tools plus `codemode`; MCP tools with `exposure: codemode` are **never put
in the prompt**. The model discovers them inside a codemode script with `searchTools()` /
`describeTool()` and calls `tools.<name>({...})`. This is the same idea as Cloudflare's "Code Mode",
built into Pi, so no extra proxy is needed.

Measured with Pi 1.5.0, REA 6.8.0 (229 tools), chrome-devtools-mcp 1.12.0 (32 tools) and superpowers
7.0.1 all loaded, first turn (`pi --print`):

| Part | Size |
|---|---|
| System prompt (incl. skill index of 16 skills) | ~10.6 KB |
| 5 declared tools (`read`, `bash`, `edit`, `write`, `codemode`) | ~4.8 KB |
| superpowers bootstrap (injected user message) | ~4.5 KB |
| **Total** | **~20 KB ≈ 5.5–6.5k tokens** |

That leaves ~25k tokens of a 32k window for the conversation. Re-measure on your own model with
`./scripts/measure-context.sh` (it reports the input tokens the server billed). If it comes in high:

1. `PI_CODEMODE_MODE=only` (one tool declared).
2. `CHROME_SLIM=1`.
3. Drop the superpowers bootstrap: add `{"packages":[{"source":"git:github.com/obra/superpowers@<ref>","extensions":[]}]}` to `settings.local.json` (skills stay available via `/skill:<name>`).

Small models that struggle to write codemode JavaScript can use `PI_MCP_EXPOSURE=deferred`: tools are
then classic tool calls, loaded on demand by `tool_search`.

## REA notes

- The default family scope covers web, Electron and JavaScript targets, which need **no native
  engine**. For Mach-O/ELF/PE work install Ghidra into the image (or mount it) and set
  `GHIDRA_INSTALL_DIR` + `JAVA_HOME` in `mcp.local.json` under `mcpServers.rea.env`.
- REA's browser tools want a loopback CDP endpoint: use `http://127.0.0.1:9222` (the shared Chromium).
- `rea doctor --client pi --json` inside the container reports the registration state.

## Chromium

One headless Chromium runs per container (`docker/start-chromium.sh`, auto-restarted), with the
DevTools protocol on `127.0.0.1:9222`. It runs with `--no-sandbox` because Chrome's sandbox cannot start
inside Docker without extra privileges; the container itself runs as a non-root user with
`no-new-privileges`. Extra flags: `CHROMIUM_EXTRA_ARGS`.

## Pinned versions (Dockerfile `ARG`s)

Node 24.22.2 · `@earendil-works/pi-coding-agent` 1.5.0 · `rea-agents` 6.8.0 · `chrome-devtools-mcp` 1.12.0 ·
superpowers `2ce8aa1` (v7.0.1). Bump with `docker compose build --build-arg PI_VERSION=...`.
