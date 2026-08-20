---
description: Review Claude Code's own OTel tool_decision events, surface which routing decisions still rely on in-session human judgment, and propose deterministic hook/settings hardening.
allowed-tools: Read, Edit, Bash(cat:*), Bash(node:*), Bash(jq:*)
---

# routing-review

Run the deterministic-routing betterment loop over Claude Code's own OpenTelemetry event log (`services.claudeOtel`, `modules/shared/claude-otel.nix`). The goal: find tool/skill routing decisions that are still being approved by a human in the moment (`user_temporary`/`user_permanent`) rather than by a `PreToolUse` hook or static config, and turn recurring ones into concrete deterministic rules — the same loop that produced `pretooluse-bash-guard.js`, but continuously fed by real usage instead of memory.

## 1. Load the log

Read `~/.local/state/claude-otel/events.jsonl` (path from `services.claudeOtel.eventsFile`, default shown). If it is missing or empty, report **"no telemetry events yet"** and suggest running `nix run .#claude-otel-doctor` to confirm the collector is actually receiving from Claude Code — then stop.

## 2. Parse and correlate

Each line is one JSON object, the raw OTLP logs payload as the collector's file exporter writes it — **not** a flat `{event, ...}` record. The shape (confirmed by direct probe against the collector, 2026-08-20):

```json
{"resourceLogs":[{"resource":{...},"scopeLogs":[{"scope":{...},"logRecords":[
  {"timeUnixNano":"...","body":{"stringValue":"..."},
   "attributes":[{"key":"event.name","value":{"stringValue":"claude_code.tool_decision"}}, ...]}
]}]}]}
```

Flatten each line's `resourceLogs[].scopeLogs[].logRecords[]`, and for each record turn its `attributes[]` array (`{key, value: {stringValue|intValue|...}}` pairs) into a plain map. Filter to records whose `event.name` attribute is `claude_code.tool_decision`. Relevant attributes per record (from that flattened map):

- `tool_name`, `tool_use_id`
- `decision` — `accept` or `reject`
- `source` — `config`, `hook`, `user_permanent`, `user_temporary`, `user_abort`, `user_reject`
- `tool_parameters` (present because `OTEL_LOG_TOOL_DETAILS=1`): `skill_name`, `mcp_server_name`/`mcp_tool_name`, `bash_command`/`full_command`, `subagent_type`, depending on tool type

A `jq` one-liner to flatten is the fastest path: `jq -c '.resourceLogs[].scopeLogs[].logRecords[] | {attrs: (.attributes | map({(.key): (.value.stringValue // .value.intValue // .value.boolValue)}) | add)}' events.jsonl`.

## 3. Summarize

Group by `(tool_name, source)` and count occurrences. Present a concise table:

| tool_name | source | count | latest ts | example (skill/mcp/command) |
|-----------|--------|-------|-----------|------------------------------|

Note `hook`/`config` volume in one line beneath the table — those are **already deterministic**, not the focus of this review, just context for how much of total routing is already hardened.

## 4. Diagnose and propose hardening

For each group where `source` is `user_temporary` or `user_permanent` with **count >= 2**: this is the hardening backlog — a routing decision still requiring a human in the loop, repeatedly. For each such group:

- Identify the concrete pattern (same tool + same command shape, same MCP server, same skill).
- Propose a specific fix: a new/extended `PreToolUse` matcher rule in `.claude/settings.json`, or a config-level permission addition — whichever matches how existing deterministic rules in this repo are expressed (see `.claude/hooks/pretooluse-bash-guard.js` and its registration in `.claude/settings.json` for the current pattern).

Also surface, separately, the top `skill.name`/`mcp_tool.name` values by overall frequency across all decisions (not just `user_*`) — heavily-used skills/connectors are candidates worth a dedicated slash command if they're being reasoning-routed every time rather than invoked directly.

**Do not autonomously rewrite `.claude/settings.json` or any hook file.** Present each proposed fix (the file, the problem, the diff) and **ask for confirmation** before editing. Apply with `Edit` only after I approve. Autonomous rewriting is out of scope per project policy (same rule as `/superhook-review` and `/pretooluse-review`).

## 5. Stamp the state file

After review, update `.claude/hooks/.routing-review-state.json`: read the JSON (or start from `{}` if absent), set a top-level `reviewedAt` to the current ISO timestamp, and write it back.

```bash
node -e 'const f=".claude/hooks/.routing-review-state.json";const fs=require("fs");let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}s.reviewedAt=new Date().toISOString();fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")'
```

## 6. Note on log hygiene

Unlike `superhook.log`, `events.jsonl` is rotated automatically by the collector's file exporter (`max_megabytes: 50`, `max_backups: 5`) — no manual truncation step is needed here. Old rotated files live alongside it under `~/.local/state/claude-otel/`; safe to delete after review if disk space matters, but not required.
