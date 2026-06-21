#!/usr/bin/env node
/**
 * UserPromptSubmit hook — background-team delegation policy.
 *
 * Fires on every user prompt and injects a standing instruction steering the
 * main agent to act as an orchestrator: substantive tasks are delegated to a
 * background team of specialized subagents (Agent tool, run_in_background:true),
 * the main thread stays free to accept the next task, and background agents'
 * interrupts / questions are answered as they arrive.
 *
 * Protocol: reads the UserPromptSubmit event JSON from stdin (ignored), prints
 * a JSON object whose hookSpecificOutput.additionalContext is appended to the
 * model's context for this turn, exits 0.
 */

// Drain stdin so the hook does not block; contents are not needed.
try {
  require("node:fs").readFileSync(0, "utf8");
} catch {
  /* no stdin — fine */
}

const additionalContext = [
  "ORCHESTRATION POLICY (background team):",
  "- You are the orchestrator. For any SUBSTANTIVE task — multi-step work, a",
  "  change spanning more than one file, research, or anything non-trivial —",
  "  do NOT do the work inline. Decompose it and delegate to a background team",
  "  of specialized subagents via the Agent tool with run_in_background: true,",
  "  choosing the most fitting subagent_type per piece (e.g. Explore for search,",
  "  platform-compiler for Nix evaluation, Plan for design, general-purpose",
  "  otherwise). Launch independent pieces in a single message so they run",
  "  concurrently.",
  "- After delegating, return control promptly and stay ready for the next task.",
  "  Do not block the main thread waiting on background agents.",
  "- When a background agent surfaces an interrupt, question, or completion,",
  "  respond to it accordingly: answer the question, unblock it, relay its",
  "  result, or spawn follow-up work. Use SendMessage to continue a specific",
  "  agent with its context intact.",
  "- EXCEPTIONS (handle inline, no delegation): pure conversational replies,",
  "  quick factual questions, and trivial one-line edits. When unsure whether a",
  "  task is substantive, prefer delegating.",
].join("\n");

process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext,
    },
    suppressOutput: true,
  }),
);
process.exit(0);
