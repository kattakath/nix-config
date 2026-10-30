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
 * STATE IS PER USER, NOT PER CHECKOUT (2026-10-30). A fleet sweep covers every
 * repo whichever checkout ran it, but the timestamp used to live in
 * `.claude/hooks/.fleet-doctor-state.json` of the checkout that ran it — so every
 * worktree session (this fleet starts them in `.claude/worktrees/*` constantly)
 * read no file and got a false "never run" nudge. It now lives at
 * `${XDG_STATE_HOME:-~/.local/state}/nix-config/fleet-doctor-state.json`, the
 * path the /fleet-doctor command's step 6 writes. The old per-checkout file is
 * still READ (never written) when the new one is absent, so a sweep stamped
 * before the move is not forgotten.
 *
 * This is a read-only reporter: it NEVER throws, NEVER blocks, and always
 * exits 0. Stdout from SessionStart is shown to the user and added to context.
 */

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const NUDGE_DAYS = 3;

try {
  const stateDir = path.join(process.env.XDG_STATE_HOME || path.join(os.homedir(), ".local", "state"), "nix-config");
  const legacyPath = path.join(process.env.CLAUDE_PROJECT_DIR || process.cwd(), ".claude", "hooks", ".fleet-doctor-state.json");
  const readState = (f) => JSON.parse(fs.readFileSync(f, "utf8"));

  let state = null;
  try {
    try {
      state = readState(path.join(stateDir, "fleet-doctor-state.json"));
    } catch {
      state = readState(legacyPath);
    }
  } catch {
    // Never run before — nudge once so the tool gets discovered.
    process.stdout.write(
      "fleet-doctor: never run — run /fleet-doctor to sweep branches/PRs/CI/pins/GC/hosts across the fleet.\n",
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
