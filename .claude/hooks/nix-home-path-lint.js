#!/usr/bin/env node
/**
 * PostToolUse home-path lint (Write|Edit), .nix only.
 *
 * Enforces the runtime-path direction of the "Paths — two axes" convention
 * (CLAUDE.md § Conventions): a *runtime* path must be $HOME/XDG-relative, never a
 * hardcoded per-user home dir. So a `.nix` VALUE line containing `/Users/<name>/`
 * or `/home/<name>/` is flagged for reconsideration (use $HOME / XDG /
 * config.home.homeDirectory instead).
 *
 * Deliberately NOT flagged (the other axis): Nix SOURCE path literals like
 * `../../claude/CLAUDE.md` — those are eval-relative to the .nix file, copied to
 * /nix/store, and MUST be repo-relative. This lint only ever sees absolute
 * /Users//home/ strings, which are never source literals, so that axis is safe.
 *
 * Advisory, not a hard gate: comment lines are ignored, and a hardcoded home
 * path can rarely be intentional — so it surfaces the finding to Claude (exit 2,
 * message on stderr) to reconsider, without reverting the write. Never wedges a
 * turn: any unexpected error exits 0.
 *
 * Input: hook JSON on stdin (tool_input.file_path), same as autostage-nix.js.
 */

const fs = require("node:fs");
const path = require("node:path");

// A per-user home dir: /Users/<name>/ (macOS) or /home/<name>/ (Linux), where
// <name> starts lowercase (so /Users/Shared, /home (no user) are NOT matched).
// The trailing / requires an actual user segment, not the bare parent dir.
const HOME_PATH = /\/(?:Users|home)\/[a-z][a-z0-9._-]*\//;

try {
  let raw = "";
  try {
    raw = fs.readFileSync(0, "utf8");
  } catch {
    process.exit(0);
  }
  if (!raw.trim()) process.exit(0);

  let evt;
  try {
    evt = JSON.parse(raw);
  } catch {
    process.exit(0);
  }

  const ti = evt.tool_input || {};
  const file = ti.file_path || (evt.tool_response && evt.tool_response.filePath) || "";
  if (!file || !file.endsWith(".nix")) process.exit(0);

  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const abs = path.resolve(projectDir, file);
  if (!abs.startsWith(path.resolve(projectDir))) process.exit(0);

  let content = "";
  try {
    content = fs.readFileSync(abs, "utf8");
  } catch {
    process.exit(0); // file gone / unreadable — nothing to lint
  }

  const hits = [];
  content.split("\n").forEach((line, i) => {
    // Strip a trailing comment so `# … /Users/ismail …` prose is ignored; only
    // the code portion of the line is linted. (A `#` inside a string alongside a
    // home path is vanishingly rare and acceptable for an advisory lint.)
    const code = line.split("#")[0];
    if (HOME_PATH.test(code)) hits.push({ n: i + 1, text: line.trim() });
  });

  if (hits.length === 0) process.exit(0);

  const rel = path.relative(projectDir, abs);
  const lines = hits
    .slice(0, 5)
    .map((h) => `  ${rel}:${h.n}: ${h.text}`)
    .join("\n");
  const more = hits.length > 5 ? `\n  …and ${hits.length - 5} more` : "";

  process.stderr.write(
    `Hardcoded per-user home path in a .nix value (CLAUDE.md § Conventions → "Paths — two axes"):\n` +
      `${lines}${more}\n` +
      `Runtime paths must be $HOME/XDG-relative — use $HOME, config.home.homeDirectory, or an XDG dir, ` +
      `not a literal /Users/<name> or /home/<name>. (Nix SOURCE path literals like ../../foo are exempt and correct — ` +
      `this only flags absolute home dirs.) Reconsider unless this absolute path is genuinely intentional.\n`,
  );
  process.exit(2); // surface to Claude to reconsider; does not revert the write
} catch {
  process.exit(0); // a PostToolUse lint must never wedge a turn
}
