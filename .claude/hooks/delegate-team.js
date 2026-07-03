#!/usr/bin/env node
/**
 * UserPromptSubmit hook — background-team delegation policy.
 *
 * Fires on every user prompt and injects a standing instruction steering the
 * main agent to act as an orchestrator/decision-maker ONLY: substantive tasks
 * are decomposed and delegated to a background team of specialized subagents
 * (Agent tool, run_in_background:true) — which may themselves nest sub-teams —
 * the main thread never idle-waits (if it's waiting, it should have delegated),
 * and background agents' interrupts / questions are answered as they arrive.
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
  "ORCHESTRATION POLICY (background team) — this repo operates orchestrator-first:",
  "- You are the ORCHESTRATOR and decision-maker, not the worker. For any",
  "  SUBSTANTIVE task — multi-step work, a change spanning more than one file,",
  "  research, root-cause investigation, or anything non-trivial — do NOT do the",
  "  work inline. Decompose it and delegate to a background team of specialized",
  "  subagents via the Agent tool with run_in_background: true, choosing the most",
  "  fitting subagent_type per piece (e.g. Explore or nix-researcher for search",
  "  and root-cause, platform-compiler for Nix evaluation, ci-release-driver for",
  "  push→CI→merge loops, Plan for design, general-purpose otherwise). Launch",
  "  independent pieces in a SINGLE message so they run concurrently.",
  "- Delegation is RECURSIVE: subagents may form their own sub-hierarchies. A",
  "  delegated agent whose slice is itself substantive is expected to further",
  "  decompose and spawn its own background sub-team rather than grind alone.",
  "- NEVER sit idle waiting on a background agent. If you are waiting, that is the",
  "  signal you should have delegated — delegate the next independent piece",
  "  instead of blocking or idle-polling. Keep the main thread free to accept the",
  "  next task and to react to agent events.",
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
