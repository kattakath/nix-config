#!/usr/bin/env node
/**
 * PostToolUse auto-stage hook (Write|Edit).
 *
 * Safety net for the git-purity rule: flakes evaluate the git tree, so a newly
 * written/edited .nix file must be `git add`ed to be visible to evaluation.
 * This stages it automatically right after the write.
 *
 * Hook input arrives as JSON on stdin (NOT via env vars). We read
 * tool_input.file_path; the earlier $CLAUDE_TOOL_FILE_PATH version was a silent
 * no-op because that variable is never populated for PostToolUse.
 *
 * Read-only-ish reporter: never throws, never blocks, always exits 0. Only acts
 * on .nix files; everything else is a silent pass.
 */

const { execSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

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
  // Write/Edit use file_path; some tools surface filePath in tool_response.
  const file = ti.file_path || (evt.tool_response && evt.tool_response.filePath) || "";
  if (!file || !file.endsWith(".nix")) process.exit(0);

  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();

  // Only stage files inside the project (defense against odd absolute paths).
  const abs = path.resolve(projectDir, file);
  if (!abs.startsWith(path.resolve(projectDir))) process.exit(0);

  try {
    execSync(`git add ${JSON.stringify(abs)}`, {
      cwd: projectDir,
      stdio: ["ignore", "ignore", "ignore"],
    });
    process.stdout.write(
      JSON.stringify({ systemMessage: `auto-staged ${file} (git-purity safety net)` }),
    );
  } catch {
    /* not a git repo / nothing to stage — silent */
  }
  process.exit(0);
} catch {
  process.exit(0); // a PostToolUse net must never wedge a turn
}
