# THE OPTION LAYER OF THE CAPSULE BOUNDARY (ADR-002 §2) — the satellite's one
# inline `flake.nix` check, carried over with its body and its comments intact,
# plus the kill-switch gate the capsule anatomy asks for.
#
# They live in a file rather than in ./flake-module.nix for the reason every
# absorbed capsule found: the satellite's flake.nix was allowed to be long
# because it was the whole repo, and a capsule's entry file is not. `module` and
# `home-manager` arrive as ARGUMENTS because a capsule leaf may not reach up
# with `../` (ast-grep/rules/capsule-must-not-reach-out.yml);
# ./flake-module.nix passes each one down.
#
# `homeDir` is a single binding rather than repeated inline literals because
# home-manager's `home.homeDirectory` must be ABSOLUTE (it is the one value that
# cannot be $HOME-relative), and a second occurrence spelled `/Users/tester/…`
# would trip ast-grep/rules/nix-hardcoded-home-path.yml — correctly, since that
# rule cannot know a fixture home from a real one.
{
  pkgs,
  home-manager,
  module,
}:
let
  homeDir = "/Users/tester";

  mkHm =
    modules:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        {
          home.username = "tester";
          home.homeDirectory = homeDir;
          home.stateVersion = "24.05";
        }
      ]
      ++ modules;
    };

  # Both services ON — the satellite's own fixture.
  hm = mkHm [
    module
    {
      services.ollamaLocal.enable = true;
      services.pgvectorLocal.enable = true;
    }
  ];

  # The module imported but NEITHER switch set — the state the two NixOS hosts
  # are in, since modules/shared/home.nix imports it unconditionally.
  hmOff = mkHm [ module ];

  # The same configuration WITHOUT the module at all, to compare against.
  hmBare = mkHm [ ];

  bool = b: if b then "yes" else "no";
  pkgNames = c: pkgs.lib.concatStringsSep " " (map (p: p.name or "?") c.config.home.packages);
in
{
  # A throwaway macOS home-manager config with BOTH services enabled, asserting
  # the options single-source correctly and the three launchd agents
  # materialise — without forcing a build of the (large) postgres / ollama
  # package closures themselves.
  #
  # TWO ASSERTIONS CARRY MORE WEIGHT THAN THE REST, and are why this is not
  # ceremony:
  #
  #   * `services.pgvectorLocal.databaseUri` is pinned as a LITERAL. That option
  #     is the seam modules/shared/mcp.nix hands to the `postgres` MCP server as
  #     `env.DATABASE_URI`, i.e. the whole career RAG (`career_docs` in `ragdb`)
  #     reaches Claude Code through this one string. Reading the option back to
  #     build the expected value would make the assertion tautological;
  #     spelling it out means a silent change to port/role/db name fails HERE
  #     rather than on the next query quietly returning nothing.
  #   * `launchd.agents.ollama.config.StandardOutPath` proves the log override
  #     merges onto UPSTREAM's `services.ollama` agent rather than forking it —
  #     upstream declares no StandardOutPath of its own. This is the shape that
  #     would have caught the `launchd.agents.ollama-local` typo ADR-002 §8
  #     found: a stale agent name silently creating a DEAD agent, invisible to
  #     `nix flake check`.
  module-evaluates =
    let
      inherit (hm.config) services launchd;
    in
    pkgs.runCommand "local-rag-eval" { } ''
      test "${pkgs.lib.boolToString services.ollama.enable}" = "true"
      test "${services.ollama.host}" = "127.0.0.1"
      test "${toString services.ollama.port}" = "11434"
      test "${services.ollamaLocal.embedModel}" = "nomic-embed-text"
      test "${toString services.ollamaLocal.embedDim}" = "768"
      test "${services.pgvectorLocal.databaseUri}" = "postgresql://mcp@127.0.0.1:5433/ragdb"
      test "${pkgs.lib.boolToString launchd.agents.ollama.enable}" = "true"
      # Proves the log override merges onto UPSTREAM's agent rather than
      # forking it — upstream declares no StandardOutPath of its own.
      test "${launchd.agents.ollama.config.StandardOutPath}" = "${homeDir}/Library/Logs/ollama-local.log"
      test "${pkgs.lib.boolToString launchd.agents.ollama-local-pull.enable}" = "true"
      test "${pkgs.lib.boolToString launchd.agents.postgres-pgvector.enable}" = "true"
      echo ok > "$out"
    '';

  # THE KILL-SWITCH GATE. modules/shared/home.nix imports this capsule
  # UNCONDITIONALLY and enables it only on `macos`, so "enable unset contributes
  # nothing" is load-bearing for nixpi and nixvm, not a nicety.
  #
  # It is also the gate that keeps ADR-002 §4's "two-switch regression" refusal
  # honest. The ADR forbids wrapping these two modules in a third
  # `programs.localRag.enable`; each gates itself on `enable && isDarwin`
  # instead. That design is only correct if an unset switch really is inert,
  # which is what this asserts — including the `home.packages` comparison
  # against a config that never imported the module at all, since
  # `services.ollama.enable = true` would otherwise drag ollama into every
  # host's profile.
  inert =
    let
      c = hmOff.config;
    in
    pkgs.runCommand "local-rag-inert" { } ''
      fail() { echo "local-rag-inert: $*" >&2; exit 1; }
      test "${pkgs.lib.boolToString c.services.ollama.enable}" = "false" \
        || fail "services.ollama.enable is true with services.ollamaLocal.enable unset"
      test "${bool (c.launchd.agents ? ollama-local-pull)}" = no \
        || fail "launchd.agents.ollama-local-pull exists with services.ollamaLocal.enable unset"
      test "${bool (c.launchd.agents ? postgres-pgvector)}" = no \
        || fail "launchd.agents.postgres-pgvector exists with services.pgvectorLocal.enable unset"
      test "${pkgNames hmOff}" = "${pkgNames hmBare}" \
        || fail "home.packages differs from a config without this module: [${pkgNames hmOff}] vs [${pkgNames hmBare}]"
      echo ok > "$out"
    '';
}
