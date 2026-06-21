#!/usr/bin/env node
/**
 * SessionStart memory loader for the Nix project.
 *
 * Surfaces the project's local, gitignored memory/ index into context at the
 * start of each session, and reminds the agent to keep it current. This is the
 * "auto-surface + auto-remind" half of project memory; actual writing is done
 * by the agent (via /remember-nix or the standing reminder), since judgement
 * about what's worth recording is not a thing a shell script can do.
 *
 * memory/ holds the candid "why" behind the repo — decisions, findings, values,
 * and an evolution timeline — and is gitignored on purpose.
 *
 * Read-only reporter: NEVER throws, NEVER blocks, always exits 0. SessionStart
 * stdout is shown to the user and added to context.
 */

const fs = require("node:fs");
const path = require("node:path");

const MAX = 60; // cap how much of the index we echo, to stay light on context.

try {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const memDir = path.join(projectDir, "memory");
  const indexPath = path.join(memDir, "INDEX.md");

  // No memory store yet: stay silent (nothing to surface).
  let exists = false;
  try {
    exists = fs.statSync(memDir).isDirectory();
  } catch {
    process.exit(0);
  }
  if (!exists) process.exit(0);

  // Count entries for a one-line summary.
  const countMd = (sub) => {
    try {
      return fs
        .readdirSync(path.join(memDir, sub))
        .filter((f) => f.endsWith(".md")).length;
    } catch {
      return 0;
    }
  };
  const decisions = countMd("decisions");
  const findings = countMd("findings");
  const values = countMd("values");

  const out = [];
  out.push(
    "PROJECT MEMORY (memory/ — gitignored, the candid 'why' behind this Nix repo):",
  );
  out.push(
    `  ${decisions} decision(s), ${findings} finding(s), ${values} value(s) on record.`,
  );

  // Echo a trimmed view of the index so the agent knows what's already captured.
  try {
    const idx = fs.readFileSync(indexPath, "utf8").split("\n");
    const trimmed = idx.filter((l) => l.trim()).slice(0, MAX);
    if (trimmed.length) {
      out.push("--- INDEX ---");
      out.push(...trimmed);
      if (idx.filter((l) => l.trim()).length > MAX) {
        out.push("  … (see memory/INDEX.md for the full index)");
      }
    }
  } catch {
    out.push("  (memory/INDEX.md not found — run /remember-nix to start the index)");
  }

  out.push(
    "REMINDER: when a significant Nix decision, finding, or value emerges this session, " +
      "record it with /remember-nix (or write directly into memory/). Keep it candid; it is " +
      "gitignored and never committed.",
  );

  process.stdout.write(out.join("\n") + "\n");
  process.exit(0);
} catch {
  // A loader must never wedge SessionStart.
  process.exit(0);
}
