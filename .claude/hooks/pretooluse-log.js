#!/usr/bin/env node
/**
 * pretooluse-log.js — pure OBSERVER for Bash/Write/Edit tool calls.
 *
 * Registered as an ADDITIONAL sibling hook alongside the existing `type: "prompt"`
 * PreToolUse gates (Bash, Write|Edit matchers) and their PostToolUse counterparts.
 * Claude Code runs all hooks under a matcher IN PARALLEL with no visibility into
 * each other's output, so this script can never see the prompt hook's block/approve
 * verdict or its reasoning text directly. What it CAN do reliably:
 *
 *   - PreToolUse invocation  -> log an "attempt" (what was called, with what args).
 *   - PostToolUse invocation -> log an "executed" (the same call actually ran, i.e.
 *     it was NOT blocked — PostToolUse never fires for a blocked call).
 *
 * `/pretooluse-review` correlates attempt/executed pairs by a content hash to infer
 * which attempts were likely blocked (attempt with no matching executed shortly
 * after) — a best-effort heuristic, not a guaranteed decision record. It cannot
 * recover the block REASON text; that is only ever visible to the orchestrating
 * model in-conversation, since prompt-type hooks are evaluated internally by the
 * harness with no logging hook of their own (unlike command-type hooks, which
 * route through .claude/hooks/superhook.js and get full reason logging).
 *
 * MUST NEVER influence the tool-call decision: always exits 0 with EMPTY stdout,
 * and swallows every possible internal error so a bug here can never masquerade
 * as, or cause, a block.
 */
"use strict";
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

try {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const logFile = path.join(projectDir, ".claude", "hooks", "pretooluse.log");
  const phase = process.argv[2] === "executed" ? "executed" : "attempt";

  let stdin = "";
  try {
    stdin = fs.readFileSync(0, "utf8");
  } catch {
    /* no stdin */
  }

  let payload = {};
  try {
    payload = JSON.parse(stdin);
  } catch {
    /* non-JSON stdin — log what little we can below */
  }

  const toolName = payload.tool_name || "unknown";
  const input = payload.tool_input || {};

  // SAFE summary only — never log file contents (Write/Edit content, old_string/
  // new_string) or command output. The Bash command TEXT itself is logged
  // (routine in this repo's own hook prompt text), truncated for log hygiene.
  let matcher = "other";
  let display = "";
  let corrKey = toolName;
  if (toolName === "Bash") {
    matcher = "Bash";
    const cmd = String(input.command || "");
    display = cmd.slice(0, 300);
    corrKey = `Bash:${cmd}`;
  } else if (toolName === "Write" || toolName === "Edit") {
    matcher = "Write|Edit";
    display = String(input.file_path || "");
    corrKey = `${toolName}:${display}`;
  } else {
    display = toolName;
    corrKey = toolName;
  }

  const corr = crypto.createHash("sha1").update(corrKey).digest("hex").slice(0, 12);
  const entry = {
    ts: new Date().toISOString(),
    phase,
    tool: toolName,
    matcher,
    corr,
    display,
  };
  fs.appendFileSync(logFile, JSON.stringify(entry) + "\n");
} catch {
  // Never let a logging bug affect the tool call — swallow everything.
}
// Always silent, always success: this hook is a bystander, never a decision-maker.
process.exit(0);
