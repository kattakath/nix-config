---
description: Review the PreToolUse attempt/outcome log for Bash and Write|Edit tool calls, surface recurring likely-blocked patterns for regular triage.
allowed-tools: Read, Edit, Bash(cat:*), Bash(node:*)
---

# pretooluse-review

Claude Code's `PreToolUse` gates for `Bash` and `Write|Edit` in this repo are `type: "prompt"`
hooks — evaluated internally by the harness, with no logging of their own and no visibility to
any sibling hook (all hooks under a matcher run in parallel). `.claude/hooks/pretooluse-log.js`
is a pure observer registered alongside them (PreToolUse: log the attempt; PostToolUse: log that
it actually ran, i.e. was NOT blocked) so recurring friction is reviewable here instead of only
ever flashing by in-conversation. Run the "fix the hook" loop over that log.

## 1. Load the log

Read `.claude/hooks/pretooluse.log`. If missing or empty, report **"no pretooluse activity
logged"** and stop.

## 2. Correlate attempts to outcomes

The log is one JSON object per line: `{ts, phase, tool, matcher, corr, display}`, where `phase`
is `"attempt"` (PreToolUse) or `"executed"` (PostToolUse).

For each `attempt` line, look for an `executed` line with the SAME `corr` and a `ts` within
~120s afterward, consuming it once matched (so a repeated identical command doesn't over- or
under-count). An `attempt` with no matching `executed` is a **likely block** — a best-effort
heuristic, not a certainty (a crashed/timed-out hook, or a pending `ask`-mode approval, can
produce the same pattern). Report it as "likely blocked," never as a confirmed fact.

## 3. Summarize

Group likely-blocked attempts by `(matcher, display)` — bucket similar `display` values (e.g.
same command prefix, same file path) — and count. Present:

| matcher | pattern | count | latest ts | example |
|---------|---------|-------|-----------|---------|

Mention total attempt / executed volume in one line beneath the table.

## 4. Diagnose recurring patterns

For any pattern with **count >= 2**, this is worth fixing. This log has NO block-reason
text — that only ever appears transiently in-conversation, since these are `prompt`-type
hooks (contrast with `command`-type hooks, which route through `.claude/hooks/superhook.js`
and get full reason logging — see `/superhook-review`). Cross-reference the pattern against
the live prompt text in `.claude/settings.json`'s `PreToolUse` block (`Bash` / `Write|Edit`
matchers) to find the rule likely responsible, and propose a concrete wording fix.

**Do not autonomously rewrite `.claude/settings.json`.** Present each proposed fix (the rule,
the problem, the wording diff) and **ask for confirmation** before editing.

## 5. Log hygiene

`pretooluse.log` is gitignored and grows fast — it logs every Bash/Write/Edit attempt, not
just blocked ones. Safe to truncate after review:

```bash
: > .claude/hooks/pretooluse.log
```

Only truncate after the review is complete and any fixes have been applied or declined.
