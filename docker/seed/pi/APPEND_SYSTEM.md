Environment: Debian container "rea-harness". Project files live under /workspace. Persistent agent state lives under /data.
A headless Chromium is already running with the DevTools protocol on http://127.0.0.1:9222; REA browser tools and chrome-devtools tools share it, so pass that endpoint when a REA tool asks for a CDP URL.
REA and chrome-devtools MCP tools are not declared directly; discover them from a codemode script with `await searchTools("...")` / `describeTool(name)` and call them as `tools.<name>({...})`.
The model behind this session has a small context window. Keep tool output narrow: ask for summaries, page results, and filter inside codemode before returning.
