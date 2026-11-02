#!/usr/bin/env node
/**
 * pretooluse-write-target.js — PreToolUse (Write|Edit): ASK before a write lands on
 * an OS system path, escapes the project with a literal `../`, or touches a file
 * that runs code or grants access at the next login, shell or git call.
 *
 * WHY A COMMAND HOOK: these path rules used to live in the prompt-type validator in
 * .claude/settings.json. A prompt hook can only return ok/not-ok, so every match was
 * a hard DENY — and an LLM judging paths was inconsistent (it approved a scratchpad
 * path and refused the same path minutes later, 2026-10-02). Operator decision
 * 2026-11-02: guards ASK, not block, wherever the action is recoverable. The prompt
 * hook keeps the one judgement that needs a model: a secret VALUE in the content.
 *
 * Silent (no decision) on the paths agents are told to use: the harness session
 * scratchpad, the gh-clones-<session> directory, sibling repos, user data folders.
 * FAIL OPEN: a malformed payload prints nothing and exits 0, so the normal
 * permission flow runs. This is an ask gate, not a boundary.
 */
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");

const HOME = os.homedir();
const SYSTEM_ROOTS = ["/etc/", "/usr/", "/var/", "/tmp/", "/System/", "/Library/", "/private/etc/", "/private/var/", "/private/tmp/"];
const LOGIN_FILES = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".profile", ".gitconfig"].map((f) => path.join(HOME, f));
const LOGIN_DIRS = ["Library/LaunchAgents", ".ssh", ".config/git"].map((d) => path.join(HOME, d) + "/");

// Harness-provisioned working space, under a system root but meant for agents.
const SCRATCHPAD = /^\/(private\/)?tmp\/claude-\d+\/[^/]+\/[^/]+\/scratchpad(\/|$)/;
const GH_CLONES = /^\/(private\/)?(var\/folders\/[^/]+\/[^/]+\/t|tmp)\/gh-clones-[^/]+(\/|$)/i;

// APFS is case-insensitive and paths can be symlinks, so `~/.ZSHRC` or a link into
// /etc would slip past a plain string compare. Each rule is checked against the
// path as written AND its real path (the target's, or its nearest existing
// parent's for a file not yet written), case-folded on darwin.
const fold = (p) => (process.platform === "darwin" ? p.toLowerCase() : p);
const F_ROOTS = SYSTEM_ROOTS.map(fold);
const F_FILES = LOGIN_FILES.map(fold);
const F_DIRS = LOGIN_DIRS.map(fold);

function realish(p) {
  let head = p;
  const tail = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync(head), ...tail);
    } catch (_) {
      const parent = path.dirname(head);
      if (parent === head) return p;
      tail.unshift(path.basename(head));
      head = parent;
    }
  }
}

function verdictFor(candidate, abs) {
  const c = fold(candidate);
  if (SCRATCHPAD.test(c) || GH_CLONES.test(c)) return null;
  if (F_FILES.includes(c) || F_DIRS.some((d) => c.startsWith(d))) {
    return `Write to ${abs} — a login/credential file Home Manager declares; it runs code or grants access next login. Allow anyway?`;
  }
  if (F_ROOTS.some((r) => c.startsWith(r))) {
    return `Write to ${abs} — an OS system path, outside the session scratchpad. Allow anyway?`;
  }
  return null;
}

function verdict(filePath, projectDir) {
  if (typeof filePath !== "string" || !filePath) return null;
  const abs = path.resolve(projectDir || process.cwd(), filePath);
  // A real path inside the scratchpad/clones is silent even when the spelled path is
  // its /tmp → /private/tmp symlink; otherwise the first rule either form hits wins.
  const real = realish(abs);
  for (const candidate of [real, abs]) {
    const c = fold(candidate);
    if (SCRATCHPAD.test(c) || GH_CLONES.test(c)) return null;
  }
  for (const candidate of new Set([abs, real])) {
    const reason = verdictFor(candidate, abs);
    if (reason) return reason;
  }
  if (projectDir && filePath.split(/[\\/]/).includes("..")) {
    const rel = path.relative(path.resolve(projectDir), abs);
    if (rel.startsWith("..")) return `Write to ${abs} — a literal '../' escaping the project. Allow anyway?`;
  }
  return null;
}

if (require.main === module) {
  let raw = "";
  process.stdin.on("data", (d) => (raw += d)).on("end", () => {
    try {
      const input = JSON.parse(raw);
      const reason = verdict((input.tool_input || {}).file_path, process.env.CLAUDE_PROJECT_DIR || input.cwd);
      if (reason) {
        process.stdout.write(JSON.stringify({
          hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: reason },
        }));
      }
    } catch (_) {
      // fail open: no output, normal permission flow
    }
    process.exit(0);
  });
}

module.exports = { verdict };
