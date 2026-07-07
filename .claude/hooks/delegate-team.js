#!/usr/bin/env node
/**
 * UserPromptSubmit hook — background-team delegation policy.
 *
 * Fires on every user prompt and injects a standing instruction steering the
 * main agent to act as an orchestrator/decision-maker ONLY: substantive tasks
 * are routed to a single persistent background 'manager' agent (Agent tool,
 * run_in_background:true) — reused via SendMessage for the rest of the
 * session once spawned, never duplicated — which itself owns decomposing and
 * fanning out to specialized subagents and may nest further sub-teams. The
 * main thread never idle-waits (if it's waiting, it should have delegated),
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
  "- You are the ORCHESTRATOR and decision-maker, not the worker — and not a",
  "  fan-out point either. For any SUBSTANTIVE task — multi-step work, a change",
  "  spanning more than one file, research, root-cause investigation, or anything",
  "  non-trivial — do NOT do the work inline, and do NOT spawn multiple",
  "  independent top-level subagents yourself. Route it through a single MANAGER",
  "  AGENT instead (below).",
  "- MANAGER AGENT: maintain exactly ONE persistent background 'manager' agent",
  "  per session; do not create a second one.",
  "  - Before dispatching any substantive task, check whether you already",
  "    spawned a manager earlier this session (you will have its agentId from",
  "    that spawn's tool result).",
  "  - If a manager already exists: hand the new instruction to it via",
  "    SendMessage (to: its agentId) instead of creating a duplicate manager or",
  "    a new top-level agent.",
  "  - If none exists yet: spawn exactly ONE (subagent_type: general-purpose,",
  "    run_in_background: true, description mentioning 'manager'), remember its",
  "    agentId for the rest of the session, and give it this task.",
  "  - The manager OWNS fan-out: it picks the fitting subagent_type per piece",
  "    (Explore or nix-researcher for search and root-cause, platform-compiler",
  "    for Nix evaluation, ci-release-driver for push→CI→merge loops, Plan for",
  "    design, general-purpose otherwise), launches independent pieces in a",
  "    single message so they run concurrently, and reports back to you.",
  "- Delegation is RECURSIVE: the manager (or any agent it spawns) may form its",
  "  own sub-hierarchies. A delegated agent whose slice is itself substantive is",
  "  expected to further decompose and spawn its own background sub-team rather",
  "  than grind alone.",
  "- NEVER sit idle waiting on a background agent. If you are waiting, that is the",
  "  signal you should have delegated — delegate the next independent piece",
  "  instead of blocking or idle-polling. Keep the main thread free to accept the",
  "  next task and to react to agent events.",
  "- When a background agent surfaces an interrupt, question, or completion,",
  "  respond to it accordingly: answer the question, unblock it, relay its",
  "  result, or spawn follow-up work. Use SendMessage to continue a specific",
  "  agent with its context intact.",
  "- WATCHDOG DUTY (every agent that spawns children, including you): auto-",
  "  notification is the primary channel, but it can silently fail — so run a",
  "  BACKUP periodic health-check as a safety net. This is a LONG fallback",
  "  heartbeat (schedule a wakeup ~1200–1800s out, or a Monitor until-loop), NOT",
  "  tight polling. On each check: let healthy in-progress children keep running,",
  "  process any that finished without notifying, and stop/kill (TaskStop) any",
  "  that are hung, stuck, or looping. Reschedule the heartbeat while children",
  "  remain active; stop once all are done. Reason about a child's ACTUAL",
  "  current state, not its last-known/stale self-report — a child that has come",
  "  to rest is DORMANT-completed, not necessarily terminated, and may re-emit",
  "  stale notifications later.",
  "- REAP BEFORE YOU EXIT: an agent with children MUST NOT come to rest/finish",
  "  while any child it spawned is still running. Before finishing, either wait",
  "  for each child to conclude (processing its result) or explicitly TaskStop the",
  "  children whose work is now moot — never leave a child orphaned. If you truly",
  "  cannot reap a child, SURFACE its id/label to your own parent (or the user) in",
  "  your final report instead of exiting silently.",
  "- ORPHANS ARE THE SPAWNER'S DEBT: recursive grandchildren report to their",
  "  immediate parent, not to the top orchestrator, so the parent owns each",
  "  child's full lifecycle end-to-end. The top orchestrator only holds ids of",
  "  agents it directly spawned and cannot reap grandchildren it never launched —",
  "  so a parent that exits with a live child creates an unsupervisable orphan.",
  "  Don't.",
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
