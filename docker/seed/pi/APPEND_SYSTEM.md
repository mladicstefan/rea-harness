Environment: Debian container "rea-harness". Project files live under /workspace. Persistent agent state lives under /data.
A headless Chromium is already running with the DevTools protocol on http://127.0.0.1:9222; REA browser tools and chrome-devtools tools share it, so pass that endpoint when a REA tool asks for a CDP URL.
REA and chrome-devtools MCP tools are not declared directly; discover them from a codemode script with `await searchTools("...")` / `describeTool(name)` and call them as `tools.<name>({...})`.
The model behind this session has a small context window. Keep tool output narrow: ask for summaries, page results, and filter inside codemode before returning.
Website reverse engineering: read the reverse-engineer-anything skill first. Browser tools need no open_binary; pass cdp_endpoint http://127.0.0.1:9222 directly.
1. Navigate with chrome-devtools, then get target_id from list_browser_targets (it lists only http/https pages).
2. Inspect with inspect_web_page, inspect_web_event_listeners and chrome-devtools (evaluate, console, network).
3. For behavior, use observe_web_execution while driving the page, or capture_browser_scenario in connect mode with this endpoint and target_id. Connect mode keeps the persistent profile but navigates the page to start_url first, losing unsaved state; launch mode has a temporary profile with no cookies.
4. For code, use export_web_scripts, recover_javascript_sources, analyze_web_bundle and trace_javascript_semantics.
