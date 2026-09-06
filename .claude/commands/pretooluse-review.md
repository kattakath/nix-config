---
description: Review the harness's own tool_decision telemetry for Bash and Write|Edit, surface recurring hook rejections, and propose prompt-rule fixes.
allowed-tools: Read, Edit, Bash(cat:*), Bash(node:*), Bash(jq:*)
---

# pretooluse-review

Claude Code's `PreToolUse` gates for `Bash` and `Write|Edit` in this repo are `type: "prompt"`
hooks — evaluated internally by the harness, invisible to any sibling hook (all hooks under a
matcher run in parallel). This command runs the "fix the hook" loop over their **actual
verdicts**.

Those verdicts come from the harness's own OTel `tool_decision` event, not from a hook. A
sibling observer hook used to *infer* blocks by correlating attempt/executed pairs on a content
hash — a heuristic that could not see a decision, a source, or a reason. It was retired: the
telemetry stream already carries all three, first-hand.

## 1. Load the stream

Read `~/.local/state/claude-otel/events.jsonl` (path from `services.claudeOtel.eventsFile`,
`modules/shared/claude-otel.nix`). Missing or empty → report **"no telemetry events yet"**,
suggest `nix run .#claude-otel-doctor` to confirm the collector is receiving, and stop.

Only the LIVE file is read here; the rotated `events-*-size.jsonl` siblings hold older history
and are worth sweeping when a longer window matters.

## 2. Flatten and filter

Each line is a full OTLP LogsData payload, **not** a flat record. Flatten
`resourceLogs[].scopeLogs[].logRecords[]` and turn each record's `attributes[]` array into a
plain map:

```bash
jq -c '.resourceLogs[].scopeLogs[].logRecords[]
       | {attrs: (.attributes | map({(.key): (.value.stringValue // .value.intValue // .value.boolValue)}) | add)}' \
   ~/.local/state/claude-otel/events.jsonl
```

Filter to records whose `event.name` attribute is `tool_decision` — **bare, no `claude_code.`
prefix**; the prefixed spelling exists only in `body.stringValue` and matching it yields
nothing. Then narrow to `tool_name` in `Bash` / `Write` / `Edit`.

Relevant attributes:

- `decision` — `accept` or `reject`
- `source` — `hook` (a PreToolUse gate decided), `config` (`permissions.allow`/`deny`),
  `user_permanent`, `user_temporary`, `user_abort`, `user_reject`
- `hook_name` — **which** hook decided, when `source` is `hook`
- `tool_name`, `tool_use_id`, `session.id`
- `tool_parameters` / `tool_input` (present because `OTEL_LOG_TOOL_DETAILS=1`) — the actual
  command or file path

Scope to the sessions you care about with `session.id`. There is **no `cwd` attribute**, so a
repo-level filter is not available — scope by session, not by directory.

## 3. Summarize

Group `decision = reject` records by `(tool_name, source, hook_name)` and bucket similar
`tool_parameters` values (same command prefix, same path). Present:

| tool_name | source | hook | pattern | count | latest ts | example |
|-----------|--------|------|---------|-------|-----------|---------|

Note total accept/reject volume in one line beneath the table, so a handful of rejections is
not read as systemic friction.

## 4. Diagnose recurring patterns

Any pattern with **count >= 2** is worth fixing. Unlike the retired heuristic, `source` and
`hook_name` name the responsible layer outright:

- `source: hook` + a `hook_name` → that hook decided. For a `command`-type hook the full reason
  text is in `.claude/hooks/superhook.log` (see `/superhook-review`). For a `prompt`-type hook
  the reason is not persisted anywhere — cross-reference the live prompt text in
  `.claude/settings.json`'s `PreToolUse` block and propose a wording fix.
- `source: config` → a `permissions.deny` rule matched; the fix is in `settings.json`'s
  `permissions`, not in a hook.
- `source: user_*` → no deterministic rule exists yet. That is `/routing-review`'s backlog,
  which reads the same stream from the other end.

**Do not autonomously rewrite `.claude/settings.json`.** Present each proposed fix (the rule,
the problem, the wording diff) and **ask for confirmation** before editing.

## 5. Log hygiene

Nothing to truncate. The collector rotates `events.jsonl` itself (`max_megabytes: 50`,
`max_backups: 5`), and the stream lives under `~/.local/state/`, never inside the repo.
