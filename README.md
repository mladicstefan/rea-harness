# rea-harness

A Docker container that runs the [Pi coding agent](https://github.com/earendil-works/pi) with
[REA](https://github.com/morluto/rea) (reverse-engineering MCP), the
[Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) on a shared headless
Chromium, and [obra/superpowers](https://github.com/obra/superpowers) skills, against a **local LLM
served from the host** by [ik_llama.cpp](https://github.com/ikawrakow/ik_llama.cpp) (any
OpenAI-compatible `/v1` server works). Three model launch scripts under `models/` are selected by
`models/start.sh`; context windows range from 32k to 256k depending on the model.

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
cp .env.example .env            # set LOCAL_LLM_BASE_URL (model fields are written by start.sh)
docker compose build
./models/start.sh               # pick a model, launch its host llama-server, sync .env, (re)create, attach
```

`./scripts/smoke.sh` checks the endpoint, Chromium, MCP servers and `rea doctor` once the container is up.

The model server runs on the **host** and must listen where the container can reach it
(`host.docker.internal:8080`). `start.sh` launches it from the chosen `models/*.sh` script; to run one by
hand, e.g.:

```bash
./models/qwen3-8-abliretrated.sh    # llama-server -m ... -c 32768 -ngl 999 --host 0.0.0.0 --port 8080
```

`host.docker.internal` is mapped to the host gateway by compose (`extra_hosts`), so the default
`LOCAL_LLM_BASE_URL=http://host.docker.internal:8080/v1` works on Linux, macOS and Windows.
No container port is published; the Chromium DevTools port stays on the container's loopback.

## Models

`./models/start.sh` lists the `models/*.sh` launch scripts with their context and inference engine
(ik_llama.cpp `llama-server` or [Strata](https://github.com/Niko1221/Strata)), restarts the host server with the one
you pick, writes `LOCAL_LLM_MODEL`, `LOCAL_LLM_CONTEXT_WINDOW` and `PI_COMPACTION_KEEP_RECENT` into `.env`
to match, recreates the container (`docker compose up -d --wait`, ending any open Pi session), then
attaches Pi.

All measurements below are on a **Ryzen 7 3700X / RTX 4070 Ti SUPER 16GB / 48GB DDR4-3000**, Q4-class
quant, KV cache `q8_0`.

| Script | Model | Context | Placement | Notes |
|---|---|---|---|---|
| `models/qwen3-8-abliretrated.sh` | Qwen3.8-27B abliterated (dense) | 32k | GPU-only (`-ngl 999`) | ~28 tok/s generation. Needs nearly the whole 16GB card (~15.1GB used, ~200MB free) — this is why `-ub` was lowered to 512. |
| `models/qwen3-5-9b-abliterated.sh` | Qwen3.5-9B abliterated (dense) | 256k | GPU-only | Fits entirely on GPU with headroom. Fast at normal context; slows at very long context (~16 tok/s near 380k in testing). An extended 384k YaRN variant was removed (unstable / quality regression). |
| `models/qwen3-6-35b-a3b-abliterated.sh` | Qwen3.6-35B-A3B abliterated (MoE, 8 of 256 experts active) | 256k default (native; `CTX=` to change) | hybrid GPU+CPU via `-ncmoe` | Expert FFN tensors live in RAM; non-expert weights + KV on GPU. KV is cheap (2 KV heads): ~1.36GB at 128k, ~2.72GB at 256k. Tune placement with `NCMOE`, context with `CTX`. See sweep below. |
| `models/qwen3-8-27b-turbo-fable-cold-fusion-735-882-heretic-uncensored-neo-coder-max-mtp.sh` | DavidAU Qwen3.8-27B TURBO Fable-Cold-Fusion (dense, Heretic/uncensored) | 64k | GPU-only, MTP self-speculation | IQ2_M (~12GB weights). Uses the model's NextN/MTP head via `--spec-type mtp`; card default reasoning (`xhigh`, `preserve_thinking` on). **128k OOMs on 16GB** with q8_0 KV (weights 11GB + 4.8GB KV); use `-ctk q4_0 -ctv q4_0` or lower `-c`. Keep temp ≤1, rep pen off or MTP acceptance drops. |
| `models/qwen3-8-flash-next-abliterated-uncensored-turbo-brilliance-50x-reasoning-instruct-gsq-rco.sh` | DavidAU Qwen3.8-Flash-Next Abliterated/Uncensored Turbo-Brilliance GSQ-RCO (MoE, 125B) | 128k (`CTX=` to change) | **Strata** engine: hot experts on GPU, all experts mmap'd from RAM/SSD, MTP draft | IQ3_S (~78GB, 2 shards). Not llama.cpp: the script derives `Strata/strata-iq3_s.128k.json` from the config Strata's setup wrote (`strata-iq3_s.json`, 64k) and runs `serve/server.py` on 0.0.0.0:8080. KV is ~13 KB/token (GDN + sparse attention), so 128k costs ~1.7GB VRAM, ~0.85GB more than Strata's 64k default, taken from the auto-sized expert cache (~10% fewer slots). Sampling defaults are the DavidAU card's (temp 1.0, top_p 0.95, top_k 64 = Strata's cap, min_p 0.05, no repeat penalty); without a `sampling` block Strata decodes greedy for clients that send none, like Pi. Needs a finished `./setup.sh` in `~/code/Strata` first. |

### Qwen3.6-35B-A3B MoE placement sweep

`-cmoe` keeps all experts in RAM (min VRAM, slowest); `-ncmoe N` keeps only the first `N` layers' experts
on CPU (lower `N` = more experts on GPU = faster, less free VRAM). TG = generation tok/s, PP = prompt
tok/s.

**128k context**

| Placement | TG | PP | VRAM used | VRAM free | |
|---|---|---|---|---|---|
| `-cmoe` | 54 | 344 | 4.1GB | 11.9GB | min VRAM baseline, slowest |
| `-ncmoe 30` | 65 | 452 | 8.8GB | 7.2GB | |
| `-ncmoe 26` | 63 | 530 | 10.7GB | 5.3GB | |
| `-ncmoe 23` | 69 | 594 | 12.1GB | 4.0GB | **recommended** (script default) |
| `-ncmoe 21` | 79 | 640 | 12.9GB | 3.1GB | aggressive, little headroom |

**64k context**

| Placement | TG | PP | VRAM used | VRAM free | |
|---|---|---|---|---|---|
| `-cmoe` | 53 | 349 | 3.5GB | 12.6GB | min VRAM baseline |
| `-ncmoe 24` | 74 | 566 | 10.9GB | 5.1GB | |
| `-ncmoe 20` | 75 | 667 | 12.7GB | 3.3GB | **recommended at 64k** |
| `-ncmoe 17` | 85 | 774 | 14.1GB | 1.9GB | aggressive |
| `-ncmoe 15` | 90 | 862 | 14.9GB | 1.1GB | aggressive, minimal headroom |

The sweep above was measured at 128k and 64k. The script now defaults to **256k** (native context) with
`-ncmoe 23`; since KV only grows ~1.36GB from 128k→256k, that config uses ~13.4GB / ~2.6GB free — derived
from the 128k numbers, re-run the sweep to confirm on your card. Minimum-VRAM config is `-cmoe` (all
experts in RAM); recommended is the default `-ncmoe 23`. Even the all-CPU baseline (~52–54 tok/s) is well
above the ~20 tok/s seen on another engine. Override placement and context at launch, e.g.:

```bash
NCMOE=21            ./models/qwen3-6-35b-a3b-abliterated.sh   # faster, less headroom
NCMOE=cmoe          ./models/qwen3-6-35b-a3b-abliterated.sh   # all experts on CPU
CTX=131072 NCMOE=21 ./models/qwen3-6-35b-a3b-abliterated.sh   # smaller window, more experts on GPU
```

### Finding the best `-ncmoe` for your card

`models/sweep-ncmoe.sh` automates the table above: it launches the model at a range of `-ncmoe` values
(and context sizes), benchmarks generation/prompt speed, and records VRAM used/free for each, so you can
pick the fastest placement that still fits. It drives the real launch script, so results match what you
actually run.

```bash
# defaults: 256k context, ncmoe cmoe,30,26,23,21
./models/sweep-ncmoe.sh models/qwen3-6-35b-a3b-abliterated.sh

# custom contexts and placements
./models/sweep-ncmoe.sh models/qwen3-6-35b-a3b-abliterated.sh --ctx 131072,65536 --ncmoe cmoe,30,23,21,17
```

Needs `curl`, `jq`, `nvidia-smi`, `python3`. It stops any running `llama-server` (it needs the GPU and
port 8080 to itself) and leaves it stopped — start your model again with `./models/start.sh` afterward.
A config that doesn't fit is reported as `FAILED/OOM` rather than crashing the sweep. Works with any MoE
launch script that honors the `NCMOE` and `CTX` environment variables.

### Pulling the models

```bash
hf download huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF Huihui-Qwen3.8-27B-abliterated-UD-IQ4_XS.gguf
hf download mradermacher/Huihui-Qwen3.5-9B-abliterated-GGUF Huihui-Qwen3.5-9B-abliterated.Q4_K_M.gguf
hf download wangzhang/Qwen3.6-35B-A3B-abliterated-GGUF Qwen3.6-35B-A3B-abliterated-Q4_K_M.gguf
hf download DavidAU/Qwen3.8-27B-TURBO-Fable-Cold-Fusion-735-882-Heretic-Uncensored-NEO-CODER-MAX-MTP-GGUF Qwen3.8-27B-TurboFCFusion-735-882-Here-Uncen-NEO-CODER-MAX-MTP-IQ2_M.gguf
# Strata model: 2 shards into ~/code/models, then prepare the pack once with Strata's setup
hf download DavidAU/Qwen3.8-Flash-Next-Abliterated-Uncensored-Turbo-Brilliance-50x-Reasoning-Instruct-GSQ-RCO-GGUF --include 'Qwen3.8-Flash-Next-GSQ-RCO-abliterated-IQ3_S/*' --local-dir ~/code/models
(cd ~/code/Strata && ./setup.sh --setup --model IQ3_S --gguf-dir ~/code/models --no-start)
```

### Codemode compatibility

Pi's **codemode** reaches MCP tools (REA, chrome-devtools) only through JavaScript written inside a
`codemode` tool call, controlled by `PI_MCP_EXPOSURE`. Not every model drives it well:

- **Qwen3.8-27B** — drives codemode reliably; keep `PI_MCP_EXPOSURE=codemode`.
- **Qwen3.5-9B** — struggles with codemode: it tries to run `codemode` / `tools.read` as shell commands and
  loops. Workaround: `PI_MCP_EXPOSURE=deferred`, which exposes MCP tools as ordinary tool calls loaded on
  demand via `tool_search`.
- **Qwen3.6-35B-A3B** — drives tools well in **`deferred`** mode (discovers via `tool_search`, makes correct
  MCP calls, recovers from schema errors). **Codemode itself is untested**; run it in `deferred` mode.

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
by `docker/render-config.sh`, which also overwrites `APPEND_SYSTEM.md` with the copy from the image. To keep manual overrides, put them in `/data/pi/settings.local.json` or
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

`REA_MAX_RESPONSE_BYTES` must be ≥ `10485760` (10 MiB) or the REA MCP server refuses to start.

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
