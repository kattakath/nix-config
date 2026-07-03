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
// Like `run`, but bounded by a timeout so a hung container start/eval cannot
// wedge the Stop gate forever.
const runLong = (cmd, ms) =>
  execSync(cmd, {
    cwd: projectDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: ms,
  });
// True only when the Docker daemon is actually reachable (not just the CLI
// installed) — `devcontainer up` needs a live daemon.
const dockerUp = () => {
  try {
    run("docker info --format '{{.ServerVersion}}'");
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

// 3. Full evaluation. Prefer host nix; else run the REAL check inside the
//    prebuilt devcontainer; else degrade to the syntax-only advisory.
if (nixFiles && has("nix")) {
  // Host has nix — evaluate directly.
  try {
    run("nix flake check --no-build 2>&1");
  } catch (e) {
    block(
      `\`nix flake check\` failed — configuration does not evaluate across all systems:\n` +
        `${(e.stdout || e.stderr || e.message || "").trim().slice(-2000)}`,
    );
  }
} else if (nixFiles && has("devcontainer") && dockerUp()) {
  // No host nix, but the devcontainer CLI + a live Docker daemon are available:
  // run the REAL `nix flake check` inside the prebuilt container. It evaluates
  // all three systems and fully builds/runs the native aarch64-linux checks;
  // only cross-arch BUILDS (x86_64-linux) still defer to CI. ~90s cold / faster
  // warm — the cost of the "every stop" gate on a Nix-less host.
  const TEN_MIN = 600000;
  let checkOut = "";
  try {
    runLong("devcontainer up --workspace-folder .", TEN_MIN);
    // Merge stderr (where nix prints the "omitted incompatible systems" warning
    // and progress) into stdout so we can parse it, and emit a marker with the
    // container's own system so the summary reports the real native target.
    checkOut = runLong(
      "devcontainer exec --workspace-folder . bash -lc " +
        "'git config --global --add safe.directory /workspaces/nix-config; " +
        "git add -A && nix flake check -L 2>&1 && " +
        'printf "\\nSTOPGATE_NATIVE=%s\\n" "$(nix eval --raw --impure --expr builtins.currentSystem)"\'',
      TEN_MIN,
    );
  } catch (e) {
    block(
      `\`nix flake check\` (run in the devcontainer) failed — configuration does not evaluate:\n` +
        `${(e.stdout || e.stderr || e.message || "").trim().slice(-2000)}`,
    );
  }
  // Compose the success message from what the run ACTUALLY reported — never
  // hardcode the system list (it would drift when a system is added/removed):
  //   native   = the container's own system (STOPGATE_NATIVE marker)
  //   deferred = nix's "omitted these incompatible systems" warning (builds only)
  //   evaluated = native + deferred (flake check EVALUATES all, BUILDS native)
  const native = (checkOut.match(/STOPGATE_NATIVE=(\S+)/) || [])[1] || "";
  const deferred = ((checkOut.match(/omitted these incompatible systems:\s*([^\n]+)/i) || [])[1] || "")
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  const evaluated = [native, ...deferred].filter(Boolean);
  const evaluatedNote =
    evaluated.length > 0
      ? `evaluated ${evaluated.length} system${evaluated.length === 1 ? "" : "s"} (${evaluated.join(", ")})`
      : "evaluated the flake";
  const nativeNote = native ? `native ${native} checks built & ran clean` : "native checks built & ran clean";
  const deferredNote =
    deferred.length > 0
      ? `cross-arch builds (${deferred.join(", ")}) defer to CI`
      : "all systems built locally — nothing deferred";
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage: `stop-gate: verified via devcontainer — \`nix flake check\` ${evaluatedNote}; ${nativeNote}. ${deferredNote}.`,
    }),
  );
  process.exit(0);
} else if (nixFiles) {
  // Neither host nix nor a usable devcontainer/Docker: parsing passed, full
  // multi-system eval must run in the devcontainer or CI.
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage:
        "stop-gate: nix unavailable on host and no devcontainer/Docker to fall back to — " +
        "validated .nix syntax only. For a REAL local check, start Docker and run `nix flake check` " +
        "inside the devcontainer (`devcontainer up --workspace-folder .` then " +
        "`devcontainer exec --workspace-folder . bash -lc 'git add -A && nix flake check -L'`). " +
        "Otherwise, full multi-system `nix flake check` (aarch64-darwin, x86_64-linux, aarch64-linux) " +
        "must pass in CI / the target environment.",
    }),
  );
  process.exit(0);
}

approve();
