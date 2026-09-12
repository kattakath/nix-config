# ---- CAPSULE: keychain-secrets (ADR-002 wave 4) -----------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-keychain-secrets flake by PLAIN COPY — history
# stays in the archived origin repo, per the operator's decision.
#
# THIS ONE IS A SECURITY SURFACE, unlike the two capsules before it. It owns the
# macOS login-Keychain `secret` CLI and the loader that exports every registered
# secret into EVERY shell. Two things are therefore load-bearing here in a way
# they were not for cloudflared-connector / firmware-secrets:
#
#   * `programs.keychainSecrets.loaderRelPath` is preserved BYTE-IDENTICAL
#     (option name, type and default). modules/darwin/core.nix:497 derives
#     `launchd.user.envVariables.BASH_ENV` from it BY REFERENCE, which is the
#     only thing closing the $BASH_ENV gap for a GUI/launchd-spawned bash. A
#     rename there is a silent loss of secrets for every non-shell-descended
#     process; ./checks/module-evaluates.nix pins the default as a literal so it
#     cannot move unnoticed.
#   * The ORDERING contract with modules/shared/claude-bedrock-gate.nix — this
#     module's `lib.mkAfter` (= mkOrder 1500) vs. the gate's `lib.mkOrder 1600`
#     on the same three shell-init options — now has a test. It could not live
#     in here (a capsule may not reach outside itself, and the gate is engine
#     code), so it is `checks.<system>.bedrock-gate-after-loader` in
#     modules/parts/checks.nix, where the engine legitimately sees both halves.
#
# WHAT MOVED, AND WHAT DID NOT:
#   modules/keychain-secrets.nix        -> ./module.nix       (byte-identical but
#                                                              for `../packages/`
#                                                              -> `./packages/`,
#                                                              which the capsule
#                                                              invariant forces)
#   packages/{secret,set-secret,remove-secret,pb-conceal}.nix -> ./packages/
#                                                              (byte-identical
#                                                              but for one stale
#                                                              in-comment path)
#   flake.nix's `module-evaluates` check -> ./checks/module-evaluates.nix
#   flake.nix's four PACKAGE checks      -> ./checks (folded into `-clis`, below)
#   tests/grammar.sh                     -> ./tests/grammar.sh (verbatim but for
#                                                              its own invocation
#                                                              line)
#   README.md                            -> ./README.md       (rehomed; Install
#                                                              now describes
#                                                              in-tree use)
#   SECURITY.md                          -> MERGED into docs/secrets-and-keychain.md
#     § The ambient-secrets threat model. It was a repo-level policy file for
#     strangers (half of it a GitHub "report a vulnerability" pointer); the half
#     that is real — "any process in the tree, including an AI agent, can read
#     every exported value via `env`" — belongs with this fleet's one secrets
#     document, not in a second policy file nobody routes to.
#   flake.nix's treefmt block + checks.treefmt -> DROPPED. This repo's own
#     treefmt.nix / `checks.formatting` already covers this tree; a capsule
#     carrying a second formatter config would be two sources of truth for one
#     `nix fmt`.
#   flake.nix's `apps`                   -> DROPPED AS DUPLICATES. nix-config has
#     always declared its own `apps.{secret,set-secret,remove-secret}` with its
#     own `meta.description` strings (modules/parts/packages.nix), pointing at
#     `config.packages.<name>` — which is now what this capsule registers. Two
#     app definitions for one binary is two descriptions to drift. `pb-conceal`
#     had an app upstream and does not here; it never had one in this fleet.
#
# THE CAPSULE INVARIANT is mechanical, not a convention: nothing in here may
# reach OUTSIDE this directory by path, enforced by
# ast-grep/rules/capsule-must-not-reach-out.yml (`files: modules/features/**`,
# `kind: path_expression`, severity error) riding the existing
# `checks.<system>.ast-grep` gate. That is why ./checks/module-evaluates.nix
# takes `module` and `home-manager` as ARGUMENTS instead of importing
# `../module.nix`.
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists → using it.
# `flake.modules.<class>.<name>` (pinned flake-parts extras/modules.nix:32-73)
# is upstream's own registry for "modules published by the flake". The class
# name `homeManager` is not invented either: it is the exact `_class` string the
# pinned home-manager stamps on its own `homeModules` option
# (home-manager flake-module.nix:33), so a module registered here is accepted
# anywhere a home-manager module is. It is NOT re-exported as a public flake
# output — modules/parts/touchup.nix owns that decision and the one-line path
# back.
{ inputs, lib, ... }:
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "keychain-secrets" ];

  # NOT `flake.modules.homeManager.…`. That option's element type is
  # `deferredModule`, whose merge wraps every definition in `{ imports = [ … ] }`
  # — which changes home-manager's module-collection order, hence the order of
  # `home.packages`, hence `home-manager-path`'s buildEnv, hence the whole
  # `darwin-system` drv. Measured in this wave; the full finding and the reason
  # the two nixos capsules do NOT need this are in modules/parts/capsules.nix
  # § The RAW module seam.
  capsuleModules.homeManager.keychain-secrets = ./module.nix;

  perSystem =
    { pkgs, ... }:
    let
      # DARWIN-ONLY, exactly as the satellite gated it
      # (`system == "aarch64-darwin"` against its three systems; `isDarwin` is
      # the same predicate against this flake's two). Every path in these CLIs
      # shells out to /usr/bin/security.
      #
      # The gate is INSIDE each output, never around the whole module body: a
      # `perSystem = { pkgs, ... }: lib.optionalAttrs pkgs.… { … }` makes the
      # MODULE'S SHAPE depend on `pkgs`, which the module system must resolve
      # before `config` is settled — measured here as
      # `infinite recursion … module argument 'pkgs' … querying _module.args`.
      # The two capsules before this one gate per-attribute for the same reason.
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

      # The CLIs. Built here rather than inside module.nix's `let` so the flake
      # `packages` and the home-manager module install the SAME derivations —
      # the satellite had exactly this split, and the argument wiring (secret
      # needs set-secret + pb-conceal; remove-secret needs set-secret) is
      # carried over unchanged so the drv paths do not move.
      set-secret = pkgs.callPackage ./packages/set-secret.nix { };
      pb-conceal = pkgs.callPackage ./packages/pb-conceal.nix { };
      secret = pkgs.callPackage ./packages/secret.nix { inherit set-secret pb-conceal; };
      remove-secret = pkgs.callPackage ./packages/remove-secret.nix { inherit set-secret; };
    in
    {
      # `pb-conceal` is deliberately NOT exported. nix-config has never carried
      # it as a package or an app — it reaches the Mac through the
      # home-manager module's `home.packages` — and publishing it now would
      # grow the public output surface in a wave whose acceptance test is that
      # the surface did not move. It is still BUILT on every PR, by the
      # `-clis` check below.
      packages = lib.optionalAttrs isDarwin { inherit set-secret remove-secret secret; };

      checks = lib.optionalAttrs isDarwin {
        keychain-secrets-module = import ./checks/module-evaluates.nix {
          inherit (inputs) home-manager;
          inherit pkgs;
          module = ./module.nix;
        };

        # The satellite's four package-checks (`inherit (self.packages.…)
        # secret set-secret remove-secret pb-conceal`), folded into ONE
        # derivation that depends on all four. Same coverage, four fewer rows
        # in `nix flake show`.
        #
        # This is not ceremony: each of the four is a `writeShellApplication`,
        # and BUILDING one runs shellcheck over its script. nix-config's darwin
        # CI leg builds `.#checks.<system>` but none of its 44 packages
        # (ADR-002 §7.4), so without this the shellcheck coverage the
        # satellite's own CI had would be silently lost on absorption — the ADR
        # calls that "the highest-cost silent loss available" and refuses it.
        keychain-secrets-clis = pkgs.runCommand "keychain-secrets-clis" { } ''
          for bin in ${secret}/bin/secret ${set-secret}/bin/set-secret \
                     ${remove-secret}/bin/remove-secret ${pb-conceal}/bin/pb-conceal; do
            test -x "$bin"
          done
          echo ok > "$out"
        '';
      };
    };
}
