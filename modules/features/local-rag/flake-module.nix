# ---- CAPSULE: local-rag (ADR-002 wave 6) ------------------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-local-rag flake by PLAIN COPY — history stays
# in the archived origin repo, per the operator's decision.
#
# WHAT THIS CAPSULE IS: the local-first RAG stack. A loopback-only launchd
# Postgres+pgvector+pgsql-http, a local Ollama embed model, and an in-DB
# `embed()` function that joins them so retrieval is plain SQL. No API key,
# nothing leaves the machine. See ./README.md.
#
# THE SEAM THAT MATTERS. `services.pgvectorLocal.databaseUri` is read by
# modules/shared/mcp.nix and handed to the gateway's `postgres` MCP server as
# `env.DATABASE_URI`. That one string is how the career RAG (`career_docs` in
# `ragdb`) reaches Claude Code, and it is the named acceptance criterion for
# this wave. ./checks/module-evaluations.nix pins its value as a LITERAL so a
# port/role/db rename fails a check instead of quietly returning zero rows.
#
# ---- WHAT MOVED, AND WHAT DID NOT ------------------------------------------
#   modules/ollama-local.nix    -> ./ollama-local.nix     BYTE-IDENTICAL
#   modules/pgvector-local.nix  -> ./pgvector-local.nix   BYTE-IDENTICAL
#     The two stay ADJACENT because pgvector-local.nix:51 does
#     `imports = [ ./ollama-local.nix ]` — that relative literal is the whole
#     reason `services.pgvectorLocal` can single-source `embedModel`/`embedDim`
#     from `services.ollamaLocal` even when a consumer imports only the
#     postgres half. Flattening them to the capsule root (rather than keeping a
#     `modules/` subdirectory) also keeps that literal a SIBLING path, which is
#     what the capsule invariant permits.
#   flake.nix's `homeManagerModules.default` -> the `localRag` binding below,
#     the same two-element `imports` attrset it always was.
#   flake.nix's `module-evaluates` check      -> ./checks/module-evaluations.nix,
#     body and comments intact, plus a second check: the `inert` kill-switch
#     gate (see that file for why it is load-bearing here and not a nicety).
#   README.md                                 -> ./README.md (rehomed; Install
#     now describes in-tree use).
#   flake.nix's treefmt block + checks.treefmt -> DROPPED. This repo's own
#     treefmt.nix / `checks.formatting` already covers this tree; a capsule
#     carrying a second formatter config would be two sources of truth for one
#     `nix fmt`. Same call the four capsules before this one made.
#
# NO PACKAGES. Unlike every other absorbed capsule this one registers no
# `perSystem.packages` — the satellite had none either. Everything it installs
# (ollama, postgresql, pgvector, pgsql-http) is nixpkgs', reached through
# `home.packages` from inside the modules. There is nothing here to shellcheck,
# so the "keep the satellite's build coverage" argument (ADR-002 §7.4) does not
# apply and no `-packages` check is invented to look symmetrical.
#
# NO `programs.localRag.enable`. ADR-002 §4 names a wrapping third switch as
# "the two-switch regression the brief forbids": `services.ollamaLocal.enable`
# and `services.pgvectorLocal.enable` each gate their own
# `config = lib.mkIf (cfg.enable && isDarwin)`, and a consumer that wants only
# the embedding half must keep being able to say so. `./checks/…`'s `inert`
# check is what makes that design honest rather than merely smaller.
#
# ---- WHY THE RAW SEAM AND NOT `flake.modules.homeManager.local-rag` ---------
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists (pinned
# flake-parts extras/modules.nix:32-73), modules/parts/capsules.nix imports it,
# and the two NIXOS capsules ride it. For a HOME-MANAGER capsule this repo has a
# second seam, `capsuleModules` (`lazyAttrsOf raw`, a definition passed through
# UNCHANGED), because `flake.modules`' element type is `deferredModule`, whose
# merge wraps every definition in `{ imports = [ … ]; }` — and for home-manager
# that wrap is observable: `home.packages` is a LIST whose merge order becomes
# `buildEnv`'s `paths` order in `home-manager-path`, which decides who wins a
# filename collision. Wave 4 measured keychain-secrets' four CLIs moving ahead
# of postgresql in that list, and `darwin-system…drv` moving with them
# (modules/parts/capsules.nix § The RAW module seam).
#
# MEASURED FOR THIS CAPSULE, both ways, rather than assumed either way:
#
#   capsuleModules.homeManager.local-rag  ┐ BOTH ->
#   flake.modules.homeManager.local-rag   ┘ /nix/store/pqsjb0dcmy0bndgzwkcaxg8fdvabwk59-
#                                             darwin-system-26.11.4cff07d.drv
#
# i.e. the wrap does NOT bite here — this capsule contributes nothing to
# `home.packages` directly (its packages arrive via upstream's own
# `services.ollama` and via `services.pgvectorLocal`, both from inside the two
# modules), so the extra level of `imports` leaves the collected order where it
# was. `capsuleModules` is chosen anyway, for two reasons that are not
# "it measured different":
#
#   1. CONSISTENCY. It is the seam the other two home-manager capsules use, and
#      the one line in compose.nix that reads them (`inherit
#      (config.capsuleModules.homeManager) …`) then carries all three.
#   2. IT KEEPS BEING TRUE. Order-insensitivity here is a property of what this
#      capsule happens to install today, not of the class. The day someone adds
#      a `home.packages` entry to ./pgvector-local.nix, `flake.modules` would
#      start moving `darwin-system`'s drv — a silent change with a green
#      `nix flake check`. capsules.nix' rule is "a class whose collection order
#      is observable uses the raw seam"; home-manager is that class regardless
#      of today's contents.
#
# (The ADR-002 wave brief for this capsule asked for
# `flake.modules.homeManager.localRag`. The deviation is the seam and the
# spelling only: it is registered, internal either way — modules/parts/touchup.nix
# suppresses `flake.modules` from the public output surface — and keyed
# `local-rag` to match the directory, like every other capsule, so
# `config.capsules` and `readDir ./modules/features` agree without a translation
# table. That equality IS `checks.capsule-registry`.)
#
# THE CAPSULE INVARIANT is mechanical, not a convention: nothing in here may
# reach OUTSIDE this directory by path, enforced by
# ast-grep/rules/capsule-must-not-reach-out.yml (`files: modules/features/**`,
# `kind: path_expression`, severity error) riding the existing
# `checks.<system>.ast-grep` gate. That is why ./checks/module-evaluations.nix
# takes `module` and `home-manager` as ARGUMENTS instead of importing upward.
{ inputs, lib, ... }:
let
  # What the satellite published as `homeManagerModules.default`, spelled the
  # same way: an attrset whose `imports` are the two sibling modules. Kept as an
  # inline definition rather than a third `module.nix` file because that file
  # would contain nothing but these two lines — and because this is the exact
  # shape modules/shared/home.nix has always imported, which is what keeps the
  # module-collection order (and therefore `darwin-system`'s drv) unmoved.
  localRag = {
    imports = [
      ./ollama-local.nix
      ./pgvector-local.nix
    ];
  };
in
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "local-rag" ];

  # The RAW seam — see the header for the measurement that rules out
  # `flake.modules` for a home-manager capsule.
  capsuleModules.homeManager.local-rag = localRag;

  perSystem =
    { pkgs, ... }:
    let
      # DARWIN-ONLY, exactly as the satellite gated its own check
      # (`system == "aarch64-darwin"` against its three systems; `isDarwin` is
      # the same predicate against this flake's two). The services themselves
      # are launchd agents, and `homeManagerConfiguration` here evaluates a
      # macOS home.
      #
      # The gate is INSIDE the output, never around the whole module body: a
      # `perSystem = { pkgs, ... }: lib.optionalAttrs pkgs.… { … }` makes the
      # MODULE'S SHAPE depend on `pkgs`, which the module system must resolve
      # before `config` is settled — measured by the earlier capsules as
      # `infinite recursion … module argument 'pkgs' … querying _module.args`.
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

      checks = import ./checks/module-evaluations.nix {
        inherit (inputs) home-manager;
        inherit pkgs;
        module = localRag;
      };
    in
    {
      checks = lib.optionalAttrs isDarwin {
        local-rag-module = checks.module-evaluates;
        local-rag-inert = checks.inert;
      };
    };
}
