#!/usr/bin/env node
/**
 * superhook.js — supervising dispatcher for command-type hooks.
 *
 * Claude Code has no native "a hook errored / decided" event, so the only way
 * to supervise hooks is to BE the hook the harness invokes. settings.json calls
 * this wrapper instead of the inner hook directly:
 *
 *     node superhook.js <EventName> -- <inner command ...>
 *
 * The wrapper forwards the event payload (stdin) to the inner command, captures
 * its stdout / stderr / exit code, and then emits the FINAL decision with full
 * authority. Its job, in order of reliability:
 *
 *   1. Crash safety  — if the inner hook throws / exits non-zero, never let it
 *      wedge the session. Decision events → safe-approve; non-decision events →
 *      silent pass (exit 0). Always logged.
 *   2. Loop breaker  — if the SAME block reason fires LOOP_LIMIT times in a row
 *      for an event, downgrade that block to approve so a mis-firing gate can't
 *      trap the agent forever. Loudly logged + surfaced via systemMessage.
 *   3. Pass-through  — otherwise the inner hook's decision is honored verbatim.
 *      A single legitimate block (e.g. git-purity) is NOT downgraded.
 *   4. Log + recommend — every invocation is appended to superhook.log as a
 *      JSON line. On crash / loop-break, a systemMessage points at the log and
 *      recommends a fix. The wrapper NEVER edits hook files itself.
 *
 * Scope note: security gating (the secret / path-traversal PreToolUse) is a
 * prompt-type hook evaluated by the model, not a shell command — it does not
 * route through this wrapper and therefore can never be overridden here.
 */

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const hooksDir = path.join(projectDir, ".claude", "hooks");
const logFile = path.join(hooksDir, "superhook.log");
const stateFile = path.join(hooksDir, ".superhook-state.json");

const LOOP_LIMIT = 3; // identical consecutive blocks before the loop breaker fires.

// Events that yield an approve/block decision the harness acts on. Others
// (UserPromptSubmit, SessionStart, PostToolUse) only emit context/text, so a
// crash there just means "emit nothing and let the turn proceed".
const DECISION_EVENTS = new Set(["Stop", "StopFailure", "SubagentStop", "PreToolUse"]);

// ---- argv: <EventName> -- <inner command ...> --------------------------------
const argv = process.argv.slice(2);
const sep = argv.indexOf("--");
const event = argv[0] || "Unknown";
const innerCmd = sep >= 0 ? argv.slice(sep + 1).join(" ") : "";
const isDecision = DECISION_EVENTS.has(event);

// ---- read the event payload so we can forward it ----------------------------
let stdin = "";
try {
  stdin = fs.readFileSync(0, "utf8");
} catch {
  /* no stdin — fine */
}

// ---- helpers ----------------------------------------------------------------
const now = () => new Date().toISOString();
const log = (entry) => {
  try {
    fs.appendFileSync(logFile, JSON.stringify({ ts: now(), event, ...entry }) + "\n");
  } catch {
    /* logging must never throw */
  }
};
const readState = () => {
  try {
    return JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch {
    return {};
  }
};
const writeState = (s) => {
  try {
    fs.writeFileSync(stateFile, JSON.stringify(s));
  } catch {
    /* best effort */
  }
};
const emit = (obj) => {
  if (obj !== undefined) process.stdout.write(JSON.stringify(obj));
  process.exit(0);
};
const hash = (s) => crypto.createHash("sha1").update(String(s)).digest("hex").slice(0, 12);

// Nothing to run: behave as a no-op pass so a mis-wired entry can't wedge us.
if (!innerCmd) {
  log({ action: "noop", note: "no inner command after --" });
  emit(isDecision ? { decision: "approve" } : undefined);
}

// ---- run the inner hook -----------------------------------------------------
let res;
try {
  res = spawnSync(innerCmd, {
    cwd: projectDir,
    shell: true,
    input: stdin,
    encoding: "utf8",
    timeout: 55_000,
  });
} catch (e) {
  res = { status: -1, stdout: "", stderr: String(e && e.message) };
}

const status = res.status;
const out = (res.stdout || "").trim();
const err = (res.stderr || "").trim();

// ---- 1. crash safety --------------------------------------------------------
if (status !== 0 || res.error) {
  const detail = (err || (res.error && res.error.message) || `exit ${status}`).slice(-1000);
  log({
    action: "crash-safe",
    status,
    stderr: detail,
    recommendation:
      `Inner ${event} hook failed (exit ${status}). superhook safe-approved to ` +
      `keep the session alive. Review the command and fix the script; consider ` +
      `running it manually with the logged payload to reproduce.`,
  });
  emit(
    isDecision
      ? {
          decision: "approve",
          systemMessage:
            `superhook: inner ${event} hook crashed (exit ${status}) — safe-approving so the ` +
            `session isn't wedged. Logged to .claude/hooks/superhook.log. The gate did NOT run; ` +
            `re-run it manually once fixed.`,
        }
      : undefined,
  );
}

// ---- parse the inner decision (decision events only) ------------------------
let parsed;
if (out) {
  try {
    parsed = JSON.parse(out);
  } catch {
    /* inner emitted plain text — pass it through verbatim below */
  }
}

// ---- 2. loop breaker (only when the inner hook BLOCKS) ----------------------
const decision = parsed && parsed.decision;
if (isDecision && decision === "block") {
  const reasonHash = hash(parsed.reason || "");
  const state = readState();
  const prev = state[event] || { hash: null, count: 0 };
  const count = prev.hash === reasonHash ? prev.count + 1 : 1;
  state[event] = { hash: reasonHash, count };
  writeState(state);

  if (count >= LOOP_LIMIT) {
    state[event] = { hash: reasonHash, count: 0 }; // reset so we don't re-fire endlessly
    writeState(state);
    log({
      action: "loop-break",
      occurrences: count,
      blockedReason: (parsed.reason || "").slice(0, 500),
      recommendation:
        `The ${event} hook blocked with the SAME reason ${count}x in a row — likely a ` +
        `mis-firing gate trapping the agent. superhook downgraded it to approve. Investigate ` +
        `why the condition never clears and fix the inner hook's logic or the underlying state.`,
    });
    emit({
      decision: "approve",
      systemMessage:
        `superhook: ${event} hook blocked ${count}x with an identical reason and was ` +
        `overridden to prevent a wedge. Original reason: ${(parsed.reason || "").slice(0, 300)} ` +
        `— see .claude/hooks/superhook.log and fix the gate.`,
    });
  }
  // First/second identical block (or a new reason): honor it verbatim.
  log({ action: "pass-block", occurrences: count });
} else if (isDecision && decision === "approve") {
  // Clear any loop counter on a clean approve.
  const state = readState();
  if (state[event]) {
    delete state[event];
    writeState(state);
  }
  log({ action: "pass-approve" });
} else {
  log({ action: "pass-through", status, hadOutput: Boolean(out) });
}

// ---- 3. pass-through: emit the inner hook's output unchanged -----------------
if (out) {
  process.stdout.write(out);
  process.exit(0);
}
// No output from a decision event: default to approve. Non-decision: silent.
emit(isDecision ? { decision: "approve" } : undefined);
