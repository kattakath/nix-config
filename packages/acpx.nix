# acpx — a headless client for ACP, Zed's Agent Client Protocol.
#
# WHAT IT IS FOR. ACP is the interop layer this fleet's three coding agents
# actually share: `claude` (via @agentclientprotocol/claude-agent-acp), `grok`
# (natively, `grok agent stdio`) and `agy` (via agy_acp_server.par). acpx is the
# only maintained CLI that drives an ACP agent without an editor attached, so it
# is what makes "ask a second agent" scriptable rather than interactive.
#
# WHY NOT THE OBVIOUS ALTERNATIVES — both were evaluated 2026-09-29 and lost:
#
#   `claude mcp serve` registered into grok/agy. One command, and it exposes
#   Claude Code's 26 raw tools to the other agent. REJECTED: it enforces NO
#   permissions. Measured — user-scope `permissions.deny`, the project
#   PreToolUse guard, `--settings` with a blanket Bash deny, `--restricted` and
#   `--permission-mode plan` were each bypassed or ignored. That is Anthropic's
#   documented behaviour ("your own client is responsible for implementing user
#   confirmation"), not a bug, and this fleet's entire guardrail floor is
#   client-side. It also costs ~23k tokens of tool schema on every turn.
#
#   A2A, the Linux Foundation agent-to-agent protocol. REJECTED on transport
#   fit: every binding is HTTPS/gRPC with discovery at a signed well-known URI,
#   built so agents from different ORGANISATIONS can stay opaque to each other.
#   On one Mac under one UID that is pure cost. Decisive measurement: zero A2A
#   strings in all three agent binaries, against 686/2013/188 MCP strings.
#
# WHY pnpm AND NOT buildNpmPackage. Upstream ships pnpm-lock.yaml and no
# package-lock.json, so buildNpmPackage cannot consume it. nixpkgs' own
# fetchPnpmDeps + pnpmConfigHook is the supported path (the pnpm.fetchDeps /
# pnpm.configHook spellings still work but are DEPRECATED) — grepped
# pkgs/build-support/node/fetch-pnpm-deps for the hook before writing this.
# fetcherVersion = 4 is mandatory: 2 was REMOVED in the 26.11 release.
# Upstream declares packageManager pnpm@11.27.1; nixpkgs pins 11.25.0. The
# lockfile format is unchanged across that patch range, so the minor skew is
# accepted rather than vendoring a second pnpm.
#
# NODE FLOOR IS REAL. package.json engines require node >=22.13.0 and the build
# targets node22. The fleet's default `nodejs` is 20.x, so this package pins
# nodejs_22 explicitly instead of inheriting — an acpx run under node 20 fails
# at import, not with a friendly version message.
{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs_22,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  makeWrapper,
}:
let
  version = "0.19.3";
in
stdenv.mkDerivation (finalAttrs: {
  pname = "acpx";
  inherit version;

  src = fetchFromGitHub {
    owner = "openclaw";
    repo = "acpx";
    tag = "v${version}";
    hash = "sha256-LpVKqp8LHyljlElLccOZE4dJJVUQ40AI89STQLc10UY=";
  };

  nativeBuildInputs = [
    nodejs_22
    # pnpm itself is REQUIRED alongside the hook: the deprecated pnpm.configHook
    # pulled the binary in implicitly, the top-level pnpmConfigHook does not and
    # fails with "'pnpm' binary not found in PATH".
    pnpm
    pnpmConfigHook
    makeWrapper
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 4;
    hash = "sha256-IwhKoL4W0ukJ3TBjLZm6fcqd8+0rx4FvVfVcJ0zVkI0=";
  };

  buildPhase = ''
    runHook preBuild
    pnpm run build
    runHook postBuild
  '';

  # `files` in package.json is dist + skills; node_modules is needed at runtime
  # because the build is bundled per-entrypoint, not fully self-contained.
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/acpx"
    cp -r dist node_modules package.json "$out/lib/acpx/"
    [ -d skills ] && cp -r skills "$out/lib/acpx/" || true
    makeWrapper ${lib.getExe nodejs_22} "$out/bin/acpx" \
      --add-flags "$out/lib/acpx/dist/cli.js"
    runHook postInstall
  '';

  meta = {
    description = "Headless client for ACP (Agent Client Protocol) — drives Claude Code, Grok Build and Antigravity over one protocol";
    homepage = "https://github.com/openclaw/acpx";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
    mainProgram = "acpx";
  };
})
