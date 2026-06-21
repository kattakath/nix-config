#!/usr/bin/env node
/**
 * Stop lifecycle gate for the Nix / Home-Manager mono-repo.
 *
 * Runs when an agent execution block is about to finish. It verifies the
 * configuration is in a trustworthy state before allowing the stop:
 *   1. Git purity — no untracked `.nix` files (flakes ignore untracked files).
 *   2. Syntax validity — every tracked `.nix` file parses.
 *   3. Flake evaluation — `nix flake check` passes if `nix` is available;
 *      otherwise the gate degrades to syntax-only and says so explicitly.
 *
 * Protocol: reads the Stop hook event JSON from stdin, prints a decision
 * object to stdout, exits 0. `{"decision":"block","reason":...}` keeps the
 * agent working; `{"decision":"approve"}` lets it stop.
 */

const { execSync } = require("node:child_process");

const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const run = (cmd) =>
  execSync(cmd, { cwd: projectDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
const has = (bin) => {
  try {
    run(`command -v ${bin}`);
    return true;
  } catch {
    return false;
  }
};
const approve = () => {
  process.stdout.write(JSON.stringify({ decision: "approve" }));
  process.exit(0);
};
const block = (reason) => {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
};

// Read (and ignore the contents of) the event payload so stdin is drained.
let raw = "";
try {
  raw = require("node:fs").readFileSync(0, "utf8");
} catch {
  /* no stdin — fine */
}
try {
  const evt = raw ? JSON.parse(raw) : {};
  // Avoid infinite loops: if a previous stop hook already blocked, don't re-block.
  if (evt.stop_hook_active) approve();
} catch {
  /* non-JSON stdin — proceed */
}

// Not a git repo or no nix files yet: nothing to gate.
try {
  run("git rev-parse --is-inside-work-tree");
} catch {
  approve();
}

// 1. Git purity — untracked .nix files make flake evaluation untrustworthy.
let untracked = "";
try {
  untracked = run("git ls-files --others --exclude-standard -- '*.nix'").trim();
} catch {
  /* ignore */
}
if (untracked) {
  block(
    `Git purity violation: untracked .nix files are invisible to flake evaluation. ` +
      `Run \`git add -A\` before finishing. Untracked:\n${untracked}`,
  );
}

// 2. Syntax — every tracked .nix file must parse.
let nixFiles = "";
try {
  nixFiles = run("git ls-files -- '*.nix'").trim();
} catch {
  /* ignore */
}
if (nixFiles && has("nix-instantiate")) {
  for (const f of nixFiles.split("\n").filter(Boolean)) {
    try {
      run(`nix-instantiate --parse ${JSON.stringify(f)} > /dev/null`);
    } catch (e) {
      block(`Nix syntax error in ${f}:\n${(e.stderr || e.stdout || e.message || "").trim()}`);
    }
  }
}

// 3. Full evaluation when nix is present; otherwise degrade gracefully.
if (nixFiles && has("nix")) {
  try {
    run("nix flake check --no-build 2>&1");
  } catch (e) {
    block(
      `\`nix flake check\` failed — configuration does not evaluate across all systems:\n` +
        `${(e.stdout || e.stderr || e.message || "").trim().slice(-2000)}`,
    );
  }
} else if (nixFiles) {
  // No nix on host: parsing passed, full multi-system eval must run in CI.
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage:
        "stop-gate: nix unavailable on host — validated .nix syntax only. " +
        "Full multi-system `nix flake check` (aarch64-darwin, x86_64-linux, aarch64-linux) " +
        "must pass in CI / the target environment.",
    }),
  );
  process.exit(0);
}

approve();
