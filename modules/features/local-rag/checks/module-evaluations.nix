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
      local.rag.ollama.enable = true;
      local.rag.pgvector.enable = true;
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
  #   * `local.rag.pgvector.databaseUri` is pinned as a LITERAL. That option
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
      inherit (hm.config) services launchd local;
    in
    pkgs.runCommand "local-rag-eval" { } ''
      test "${pkgs.lib.boolToString services.ollama.enable}" = "true"
      test "${services.ollama.host}" = "127.0.0.1"
      test "${toString services.ollama.port}" = "11434"
      test "${local.rag.ollama.embedModel}" = "nomic-embed-text"
      test "${toString local.rag.ollama.embedDim}" = "768"
      test "${local.rag.pgvector.databaseUri}" = "postgresql://mcp@127.0.0.1:5433/ragdb"
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
        || fail "services.ollama.enable is true with local.rag.ollama.enable unset"
      test "${bool (c.launchd.agents ? ollama-local-pull)}" = no \
        || fail "launchd.agents.ollama-local-pull exists with local.rag.ollama.enable unset"
      test "${bool (c.launchd.agents ? postgres-pgvector)}" = no \
        || fail "launchd.agents.postgres-pgvector exists with local.rag.pgvector.enable unset"
      test "${pkgNames hmOff}" = "${pkgNames hmBare}" \
        || fail "home.packages differs from a config without this module: [${pkgNames hmOff}] vs [${pkgNames hmBare}]"
      echo ok > "$out"
    '';

  # THE UPSTREAM-SEAM GATE — the one check that would go red if someone "adopted"
  # nix-darwin's `services.postgresql` for the daemon half.
  #
  # WHY THIS IS NOT CEREMONY. That adoption is the obvious-looking conventionality
  # fix (the option genuinely exists, pinned nix-darwin
  # modules/services/postgresql/default.nix:41-275), and every way it regresses is
  # SILENT — a green `nix flake check`, a running cluster, and a consumer that
  # reads zero rows or an agent macOS never restarts. ./pgvector-local.nix's header
  # carries the full citation; this pins the four properties it turns on, each
  # against the upstream line that would move it:
  #
  #   LANE      upstream renders `launchd.user.agents.postgresql` (:335), which
  #             modules/darwin/launchd-sources.nix records as
  #             `selfHeals = false; domain = "gui"` — reached by neither
  #             home-manager's probe nor launchd-reconcile.nix. The existing
  #             `module-evaluates` check asserts the agent EXISTS; this asserts it
  #             exists in the HOME-MANAGER lane, which is the half that self-heals.
  #   arg0      upstream's `script` renders `[ "/bin/sh" "-c" … ]`
  #             (nix-darwin modules/launchd/default.nix:88-93) —
  #             .claude/rules/launchd-naming.md, and the TCC attribution failure
  #             modules/shared/launchd-launcher.nix was built to prevent. A store
  #             path here is the property that rule protects; `/bin/sh` is the
  #             regression. ast-grep cannot see it, because the offending literal
  #             would live in the pinned input, not in this repo.
  #   SUPERUSER upstream's `superUser` is `internal` + `readOnly` = "postgres"
  #             (:265-274) and it runs `initdb -U ${cfg.superUser}` (:345), so the
  #             login user stops being the socket superuser and this capsule's
  #             password-free `peer` admin path breaks. Asserting `--auth=peer`
  #             with `-U "$OSUSER"` pins the no-secret model itself.
  #   DATADIR   upstream defaults `dataDir` to `/var/lib/postgresql/<psqlSchema>`
  #             (:316) and initdb's a FRESH cluster whenever `PG_VERSION` is absent
  #             (:340-350). A moved dataDir leaves the live `ragdb` on disk but
  #             invisible, which is data loss from every consumer's point of view.
  #             This pins the data directory under the home directory.
  #
  # The negative assertion matters as much as the positives: upstream's `mkAfter`
  # tail is `host all all 127.0.0.1/32 md5` (:322) — every database for every role
  # over TCP. This capsule's wrapper must emit no `md5` at all.
  upstream-postgresql-seam =
    let
      inherit (hm.config) launchd local;
      runner = builtins.head launchd.agents.postgres-pgvector.config.ProgramArguments;
    in
    pkgs.runCommand "local-rag-upstream-postgresql-seam" { } ''
      fail() { echo "local-rag-upstream-postgresql-seam: $*" >&2; exit 1; }

      # LANE: the home-manager agent set is the self-healing one.
      test "${bool (launchd.agents ? postgres-pgvector)}" = yes \
        || fail "no home-manager launchd.agents.postgres-pgvector — did the daemon move to nix-darwin's launchd.user.agents (selfHeals = false)?"

      # arg0: a store-resident wrapper, never Apple's shell.
      case "${runner}" in
        /nix/store/*) : ;;
        *) fail "agent arg0 is not a store path: ${runner}" ;;
      esac
      case "${runner}" in
        */bin/sh|*/bin/bash|*/bin/zsh) fail "agent arg0 is a bare interpreter: ${runner}" ;;
      esac

      # SUPERUSER: the login user owns the cluster, over the socket, via peer. The
      # pattern skips the two shell variables rather than escaping them — a `\$` in
      # a Nix indented string is a literal backslash, not an escaped dollar, so
      # spelling them out would silently never match and the check would pass blind.
      grep -q 'initdb -D .* -U .* --auth=peer' ${runner} \
        || fail "the cluster superuser is no longer the login user under peer auth (upstream pins superUser = \"postgres\")"

      # No password auth anywhere: upstream's mkAfter tail would add md5 for all.
      # `if`, not `&&` — a `grep && fail` compound that finds nothing returns 1 and
      # trips errexit, i.e. the negative assertion would fail on the GOOD case.
      if grep -q 'md5' ${runner}; then
        fail "the wrapper emits an md5 pg_hba rule — upstream's default tail opens every db to every role over TCP"
      fi

      # DATADIR: under the home directory, so the live cluster is never orphaned.
      case "${local.rag.pgvector.dataDir}" in
        ${homeDir}/*) : ;;
        *) fail "dataDir left the home directory (${local.rag.pgvector.dataDir}); upstream's default is /var/lib/postgresql/<psqlSchema> and initdb's a fresh cluster" ;;
      esac

      echo ok > "$out"
    '';

  # THE pg_hba GATE. The run-wrapper rewrites pg_hba.conf with a TRUNCATING
  # redirect on every launch, so a hand-added entry for a second database
  # survives only until the next restart — the consumer then gets
  # `no pg_hba.conf entry for host "127.0.0.1"` with the server plainly up.
  # (dontsell-ai/app's local dev database lost its line exactly this way;
  # diagnosed 2026-09-21.) This asserts an `extraDatabases` entry reaches the
  # generated wrapper — BOTH the auth line and the superuser `CREATE
  # EXTENSION`, since a scoped role cannot create one itself — and that the
  # RAG's own entry still survives beside it.
  extra-databases =
    let
      hmExtra = mkHm [
        module
        {
          local.rag.pgvector.enable = true;
          local.rag.pgvector.extraDatabases = [
            {
              db = "appdb";
              role = "appuser";
            }
          ];
        }
      ];
      runner = builtins.head hmExtra.config.launchd.agents.postgres-pgvector.config.ProgramArguments;
    in
    pkgs.runCommand "local-rag-extra-dbs" { } ''
      fail() { echo "local-rag-extra-dbs: $*" >&2; exit 1; }
      grep -q 'host .*appdb .*appuser .*127\.0\.0\.1/32 .*trust' ${runner} \
        || fail "extraDatabases entry never reached pg_hba.conf in the wrapper"
      grep -q 'host .*appdb .*appuser .*::1/128 .*trust' ${runner} \
        || fail "extraDatabases entry missing its IPv6 loopback line"
      grep -q 'CREATE EXTENSION IF NOT EXISTS vector' ${runner} \
        || fail "extraDatabases entry bootstraps no pgvector (scoped roles cannot CREATE EXTENSION)"
      grep -q 'host .*ragdb .*mcp .*127\.0\.0\.1/32 .*trust' ${runner} \
        || fail "the RAG store's own pg_hba entry was displaced by extraDatabases"
      echo ok > "$out"
    '';
}
