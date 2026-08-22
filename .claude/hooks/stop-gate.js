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
// Large enough for verbose `nix flake check` progress (default 1 MiB is tight
// under concurrent eval noise and can throw maxBuffer → false "check failed").
const BIG_BUF = 20 * 1024 * 1024;
const run = (cmd) =>
  execSync(cmd, {
    cwd: projectDir,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: BIG_BUF,
  });
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
    maxBuffer: BIG_BUF,
  });
/** Prefer real error lines over the last N chars of progress spam. */
const formatCheckFailure = (e) => {
  const raw = `${e.stdout || ""}\n${e.stderr || ""}\n${e.message || ""}`.trim();
  const lines = raw.split("\n");
  const hits = lines.filter((l) => /error:|failed|assertion|trace:/i.test(l));
  const body = (hits.length ? hits.join("\n") : raw).slice(-2500);
  const timedOut = /ETIMEDOUT|timed out/i.test(String(e.message || e.stderr || ""));
  if (timedOut) {
    return `timed out — re-run \`nix flake check --no-build\` manually (cold eval can exceed the gate budget).\n${body}`;
  }
  return body;
};
const approve = () => {
  process.stdout.write(JSON.stringify({ decision: "approve" }));
  process.exit(0);
};
const block = (reason) => {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
};
// Syntax passed but full multi-system eval couldn't run locally (no host nix and
// no usable devcontainer fallback). Approve with an explicit advisory rather than
// silently — the REAL check must land in the devcontainer or CI.
const syntaxOnlyAdvisory = () => {
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage:
        "⚠︎ stop-gate: nix unavailable on host and the devcontainer fallback couldn't run " +
        "(no `devcontainer` CLI, or the container failed to start — e.g. Docker daemon not running) — " +
        "validated .nix syntax only. For a REAL local check, start Docker and run " +
        "`devcontainer up --workspace-folder .` then " +
        "`devcontainer exec --workspace-folder . bash -lc 'git add -A && nix flake check -L'`. " +
        "Otherwise, full two-system `nix flake check` (aarch64-darwin, aarch64-linux) " +
        "must pass in CI / the target environment.",
    }),
  );
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
    `✘ stop-gate BLOCKED — git purity: untracked .nix files are invisible to flake evaluation. ` +
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
      block(
        `✘ stop-gate BLOCKED — Nix syntax error in ${f}:\n${(e.stderr || e.stdout || e.message || "").trim()}`,
      );
    }
  }
}

// 3. Full evaluation. Prefer host nix; else run the REAL check inside the
//    prebuilt devcontainer; else degrade to the syntax-only advisory.
if (nixFiles && has("nix")) {
  // Host has nix — evaluate directly. Budget matches superhook Stop timeout (10m).
  // Note: this only fully evaluates/builds checks for the *host* system; other
  // systems are omitted unless --all-systems (CI covers aarch64-linux).
  try {
    runLong("nix flake check --no-build 2>&1", 600_000);
  } catch (e) {
    block(
      `✘ stop-gate BLOCKED — \`nix flake check --no-build\` failed on host:\n` +
        `${formatCheckFailure(e)}`,
    );
  }
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage:
        "✔︎ stop-gate: `nix flake check --no-build` passed on host " +
        "(other systems deferred to CI when omitted as incompatible).",
    }),
  );
  process.exit(0);
} else if (nixFiles && has("devcontainer")) {
  // No host nix, but the `devcontainer` CLI is available: run the REAL
  // `nix flake check` inside the prebuilt container. It evaluates both
  // systems and fully builds/runs the native aarch64-linux checks; only the
  // cross-arch BUILD (aarch64-darwin) still defers to CI.
  // ~90s cold / faster warm — the cost of the "every stop" gate on a Nix-less host.
  //
  // Starting the container needs a live Docker daemon. Rather than shell out to a
  // separate `docker` CLI probe, we just try `devcontainer up` (bounded by the
  // timeout) and treat a START failure (daemon down, image unavailable, …) as an
  // environment limitation → syntax-only advisory, NOT a config-eval block.
  const TEN_MIN = 600000;

  // Linked git worktrees (e.g. .claude/worktrees/<branch>) have a `.git` FILE,
  // not a directory, pointing at the main repo's git-common-dir via an
  // ABSOLUTE host path — and that common dir's `worktrees/<name>/gitdir`
  // backlink points back to this checkout via another absolute host path.
  // `devcontainer up`'s workspaceMount only bind-mounts the checkout folder
  // at /workspaces/nix-config, so neither absolute pointer resolves inside
  // the container → git (and libgit2, used by nix's `git+file://` self
  // input) fails with "fatal: not a git repository: (null)". Fix: when in a
  // worktree, bind-mount the main repo's `.git` dir AND this checkout's own
  // real host path at their identical absolute paths, mirroring the host
  // layout inside the container so both pointer chains resolve.
  let extraMountArgs = "";
  let extraSafeDirs = "";
  try {
    const fs = require("node:fs");
    const path = require("node:path");
    if (fs.statSync(path.join(projectDir, ".git")).isFile()) {
      const commonDir = path.resolve(projectDir, run("git rev-parse --git-common-dir").trim());
      // Same JSON.stringify-as-shell-quoting technique as the nix-instantiate
      // call above — commonDir/projectDir are derived from git/env, not
      // attacker input, but quote them anyway for consistency and so a path
      // containing a `"` or space can't break the composed command.
      const mountArg = (dir) => `--mount ${JSON.stringify(`type=bind,source=${dir},target=${dir}`)}`;
      extraMountArgs = ` ${mountArg(commonDir)} ${mountArg(projectDir)}`;
      extraSafeDirs = `git config --global --add safe.directory ${JSON.stringify(commonDir)}; git config --global --add safe.directory ${JSON.stringify(projectDir)}; `;
    }
  } catch {
    /* main checkout (`.git` is a directory) or detection failed — no extra mounts needed */
  }

  try {
    runLong(`devcontainer up --workspace-folder .${extraMountArgs}`, TEN_MIN);
  } catch {
    // Container could not start — cannot verify here; degrade to the advisory.
    syntaxOnlyAdvisory();
  }
  let checkOut = "";
  try {
    // Merge stderr (where nix prints the "omitted incompatible systems" warning
    // and progress) into stdout so we can parse it, and emit a marker with the
    // container's own system so the summary reports the real native target.
    checkOut = runLong(
      "devcontainer exec --workspace-folder . bash -lc " +
        `'git config --global --add safe.directory /workspaces/nix-config; ${extraSafeDirs}` +
        "git add -A && nix flake check -L 2>&1 && " +
        'printf "\\nSTOPGATE_NATIVE=%s\\n" "$(nix eval --raw --impure --expr builtins.currentSystem)"\'',
      TEN_MIN,
    );
  } catch (e) {
    block(
      `✘ stop-gate BLOCKED — \`nix flake check\` (run in the devcontainer) failed — configuration does not evaluate:\n` +
        `${(e.stdout || e.stderr || e.message || "").trim().slice(-2000)}`,
    );
  }
  // Compose the success message from what the run ACTUALLY did — never hardcode
  // the system list (it would drift when a system is added/removed). Be strictly
  // truthful: `nix flake check` in the container only BUILDS the native system's
  // checks; the "omitted" systems were NOT built/verified here and defer to CI.
  //   native   = the container's own system (STOPGATE_NATIVE marker)
  //   deferred = nix's "omitted these incompatible systems" warning (not built)
  const native = (checkOut.match(/STOPGATE_NATIVE=(\S+)/) || [])[1] || "";
  const deferred = ((checkOut.match(/omitted these incompatible systems:\s*([^\n]+)/i) || [])[1] || "")
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean);
  const nativeNote = native ? `native ${native} checks built & passed` : "native checks built & passed";
  const deferredNote =
    deferred.length > 0
      ? `builds for ${deferred.join(", ")} omitted as incompatible (not verified here) → defer to CI`
      : "all buildable checks passed — nothing omitted";
  process.stdout.write(
    JSON.stringify({
      decision: "approve",
      systemMessage: `✔︎ stop-gate: ran \`nix flake check\` in the devcontainer — ${nativeNote}; ${deferredNote}.`,
    }),
  );
  process.exit(0);
} else if (nixFiles) {
  // Neither host nix nor the devcontainer CLI: parsing passed, full multi-system
  // eval must run in the devcontainer or CI.
  syntaxOnlyAdvisory();
}

approve();
