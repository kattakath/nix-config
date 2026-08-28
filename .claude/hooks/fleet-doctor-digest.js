#!/usr/bin/env node
/**
 * SessionStart digest for fleet-doctor staleness.
 *
 * Mirrors routing-review-digest.js's shape, but deliberately does NO network
 * or cross-repo work (no `git fetch`, no `gh`) — SessionStart hooks run on
 * every session and must stay fast/quiet. This only reads a local timestamp
 * written by the /fleet-doctor command (see .claude/commands/fleet-doctor.md
 * step 6) and nudges if it's been longer than NUDGE_DAYS since the last run.
 *
 * NUDGE_DAYS is a provisional placeholder (2026-08-27, no usage data yet) —
 * retune once real session cadence shows how often drift actually occurs.
 *
 * This is a read-only reporter: it NEVER throws, NEVER blocks, and always
 * exits 0. Stdout from SessionStart is shown to the user and added to context.
 */

const fs = require("node:fs");
const path = require("node:path");

const NUDGE_DAYS = 3;

try {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const statePath = path.join(projectDir, ".claude", "hooks", ".fleet-doctor-state.json");

  let state = null;
  try {
    state = JSON.parse(fs.readFileSync(statePath, "utf8"));
  } catch {
    // Never run before — nudge once so the tool gets discovered.
    process.stdout.write(
      "fleet-doctor: never run in this repo — run /fleet-doctor to sweep branches/PRs/CI/pins/GC/hosts across the fleet.\n",
    );
    process.exit(0);
  }

  const lastRunAt = state && typeof state.lastRunAt === "string" ? state.lastRunAt : null;
  if (!lastRunAt) process.exit(0);

  const ageMs = Date.now() - new Date(lastRunAt).getTime();
  if (!Number.isFinite(ageMs) || ageMs < NUDGE_DAYS * 24 * 60 * 60 * 1000) process.exit(0);

  const ageDays = Math.floor(ageMs / (24 * 60 * 60 * 1000));
  process.stdout.write(
    `fleet-doctor: last full sweep was ${ageDays}d ago (${lastRunAt}) — run /fleet-doctor when convenient.\n`,
  );
  process.exit(0);
} catch {
  // A digest reporter must never wedge SessionStart.
  process.exit(0);
}
