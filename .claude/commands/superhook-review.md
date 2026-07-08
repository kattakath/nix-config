---
description: Review superhook incident log, diagnose recurring crash-safe/loop-break failures, and propose fixes to the offending inner hook scripts.
allowed-tools: Read, Edit, Bash(cat:*), Bash(node:*)
---

# superhook-review

Run the "fix the hook" betterment loop over the supervising dispatcher's incident log. The goal is to surface *real* incidents, diagnose their root cause in the inner hook scripts, and propose concrete fixes — with you confirming before any executable hook is edited.

## 1. Load the log

Read `.claude/hooks/superhook.log`. If it is missing or empty, report **"no superhook incidents logged"** and stop — there is nothing to review.

## 2. Parse and filter

The log is one JSON object per line, with fields `ts`, `event`, `action`, plus action-specific fields. Focus only on the real incidents:

- `action == "crash-safe"` — inner hook exited nonzero (fields: `status`, `stderr`, `recommendation`).
- `action == "loop-break"` — repeated identical block detected and broken (fields: `occurrences`, `blockedReason`, `recommendation`).

Treat `pass-approve`, `pass-block`, `pass-through`, and `noop` lines as **volume context only** — count them for the totals but do not analyze them individually.

## 3. Summarize

Group incidents by `(event, action)` and count occurrences. Present a concise table:

| event | action | count | latest ts | summary |
|-------|--------|-------|-----------|---------|

Use `stderr` as the summary for `crash-safe` rows and `blockedReason` for `loop-break` rows. Mention overall pass/noop volume in one line beneath the table.

## 4. Diagnose and propose fixes for recurring incidents

For each incident group with **count >= 2**, map the event to its inner hook script and read it:

- `Stop` -> `.claude/hooks/stop-gate.js`

(Note: only `command`-type hooks route through `superhook.js`. The `prompt`-type
gates — `PreToolUse` and `SubagentStop` — are evaluated by the model, never pass
through the wrapper, and so never produce log incidents. Don't go hunting for them here.)

From the logged `stderr` / `recommendation` and the script source, diagnose the root cause and propose a concrete code fix.

**Do not autonomously rewrite executable hook files.** Present each proposed fix (the file, the problem, the diff) and **ask for confirmation** before editing. Apply with `Edit` only after I approve. Autonomous rewriting of hook scripts is out of scope per project policy.

## 5. Stamp the state file

After review, update `.claude/hooks/.superhook-state.json`: read the JSON, set a top-level `reviewedAt` to the current ISO timestamp, and write it back — **preserving every existing per-event counter key** (`{"<event>": {"hash","count"}}`). This signals the SessionStart digest to stop re-surfacing already-reviewed incidents.

```bash
node -e 'const f=".claude/hooks/.superhook-state.json";const fs=require("fs");const s=JSON.parse(fs.readFileSync(f,"utf8")||"{}");s.reviewedAt=new Date().toISOString();fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")'
```

## 6. Note on log hygiene

`superhook.log` is gitignored. If it has grown large, it may be safely truncated after review:

```bash
: > .claude/hooks/superhook.log
```

Only truncate after the review is complete and any fixes have been applied or declined.
