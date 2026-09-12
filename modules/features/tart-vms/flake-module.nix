# ---- CAPSULE: tart-vms (ADR-002 wave 5) -------------------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-tart-vms flake by PLAIN COPY — history stays
# in the archived origin repo, per the operator's decision.
#
# The biggest capsule so far (3,255 lines) and the one with the most LIVE
# surface: `macos` runs three ephemeral Tart-VM CI runners plus a GitLab lane
# off these modules, and both runner modules sit in mkDarwin's BASE list, so
# EVERY darwin composition — nix-personal's included — evaluates them.
#
# ---- THE FOUR THINGS THAT ARE LOAD-BEARING HERE -----------------------------
#
# 1. PATH IDENTITY IN THE BASE LIST. `github-runner.nix` and `gitlab-runner.nix`
#    both `imports = [ ./slots.nix ]`, and the module system dedupes modules by
#    PATH identity. The satellite said so at its own export site and exported
#    paths, not `import`ed functions, for exactly this reason: a consumer listing
#    both must not get two `tart.runnerSlots` declarations. They therefore go out
#    through `capsuleModules` (`lazyAttrsOf raw`, a definition passed through
#    UNCHANGED — modules/parts/capsules.nix § The RAW module seam) and NOT
#    through `flake.modules`, whose `deferredModule` element type wraps every
#    definition in `{ imports = [ … ] }` and would hand compose.nix two distinct
#    anonymous wrappers instead of two deduplicable paths.
#
# 2. THE UNFREE NARROWING IS KEPT, DELIBERATELY. The satellite set
#    `config.allowUnfreePredicate` to exactly three names — tart (FSL), packer
#    (BUSL) and tart-guest-agent (whose derivation sets its own
#    `meta.license.free = false`). Swapping that for a blanket
#    `allowUnfree = true` would be a real loss: the narrowing is what makes a
#    FOURTH unfree package arriving through a nixpkgs bump fail the build
#    instead of shipping silently. It cannot ride this flake's perSystem `pkgs`
#    (that is the shared instance every other output uses, and widening it would
#    weaken the whole flake), so this capsule imports its OWN nixpkgs with the
#    predicate — the narrowing is worth one extra evaluation. It is scoped to the
#    capsule's `packages`/`checks`; the darwin modules keep building against the
#    HOST's pkgs, where hosts/macos.nix:20's `allowUnfree = true` already applies
#    and nothing about the fleet build moves.
#
# 3. `darwinStubs` STAYS. ADR-002 §2 names it as the OPTION layer of the capsule
#    boundary — `lib.evalModules` against a hand-written stub of nix-darwin's
#    surface is what proves these modules do not reach outside themselves.
#    Deleting it would delete the isolation test. It lives in
#    ./checks/module-evaluations.nix now, with its known rot cost (§7.7) stated
#    there.
#
# 4. `/Users/admin` and `/Users/tester` ARE CORRECT and must survive. The first
#    is the account baked into Cirrus' macOS GUEST images (a path inside a
#    disposable VM, with no host $HOME that could stand in); the second is the
#    evalModules fixture. `nix-hardcoded-home-path` is severity ERROR, so it was
#    SCOPED — by three literal user names, each with its reason — before this
#    capsule landed. See that rule's header and its rule-test.
#
# ---- WHAT MOVED, AND WHAT DID NOT -------------------------------------------
#   modules/{darwin,github-runner,gitlab-runner,slots}.nix -> the capsule ROOT
#     (./darwin.nix, ./github-runner.nix, …), not a nested ./modules/. The only
#     edit is `../packages/x.nix` -> `./packages/x.nix` in two files, and the
#     flattening is what makes that edit possible: `..` anywhere under
#     modules/features/ is an ast-grep ERROR, even when it stays inside the
#     capsule (ast-grep/rules/capsule-must-not-reach-out.yml).
#   packages/*.nix     -> ./packages/ VERBATIM, except tart-vm.nix, whose
#                         `defaultTemplate ? ../templates/…` default became a
#                         mandatory ARGUMENT supplied below — same path, same
#                         store path, same drv.
#   templates/vanilla-tahoe.pkr.hcl -> ./templates/ verbatim.
#   flake.nix's 5 EVAL checks  -> ./checks/module-evaluations.nix (bodies
#                                 verbatim) + ./checks/packer-template.nix.
#   flake.nix's 5 BUILD checks -> folded into ONE `tart-vms-packages` below.
#     Not ceremony: every one of these is a `writeShellApplication`, and BUILDING
#     it runs shellcheck over its script. nix-config's darwin CI leg builds
#     `.#checks.<system>` but none of its packages (ADR-002 §7.4), so without
#     this the shellcheck coverage the satellite's CI had would be silently lost.
#   flake.nix's `apps` (default, tart-vm) -> DROPPED. `nix run .#tart-vm` already
#     resolves through `packages`, and a second definition is a second
#     `meta.description` to drift (same call as the keychain-secrets capsule).
#   flake.nix's `packages.default` -> DROPPED. This flake has never had one, and
#     adding a public alias in a wave whose acceptance test is "the surface did
#     not move" is surface for its own sake.
#   flake.nix's `formatter` + nixConfig -> DROPPED. This repo's treefmt.nix and
#     modules/shared/nix-cache.nix already own both, once.
#   .github/, CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md, LICENSE ->
#     NOT copied. Seven CI pipelines collapsing into one is the point of
#     ADR-002; this repo has its own governance files and its own MIT LICENSE.
#   README.md -> ./README.md, rehomed next to the code it describes.
#
# ---- TWO STALE `modules/…` REFERENCES ARE LEFT ON PURPOSE -------------------
# The flattening above renamed `modules/slots.nix` -> `./slots.nix` and
# `modules/gitlab-runner.nix` -> `./gitlab-runner.nix`. Every reference to the
# old spelling was fixed EXCEPT two, which live inside `''…''` SHELL SCRIPT
# BODIES and therefore reach the built derivation:
#
#   packages/tart-runner.nix:473   "computed in modules/github-runner.nix"
#   packages/gitlab-tart.nix:75-76 "(modules/gitlab-runner.nix)" /
#                                  "MUST track modules/slots.nix's default"
#
# Editing either changes the script text, hence the drv, hence `home.packages`,
# hence `darwin-system` — and ADR-002's acceptance test is that this wave moves
# code without moving a single host drv. A comment fix is not worth spending
# that, so they are recorded here instead of silently rotting: fix them in the
# next change that touches those scripts for a real reason.

#
# ---- ./darwin.nix HAS NO CONSUMER TODAY, and is kept on purpose -------------
# `tart.vms.<name>` (the generic guest lifecycle module) lost its only consumer
# when `macvm` was removed on 2026-09-05. docs/macvm-readd-runbook.md is the
# standing plan to bring that host back and names this module as step 1, so
# archiving the satellite without keeping it would delete the runbook's
# subject. It is registered below and covered by `tart-vms-darwin-module`;
# nothing imports it, which is stated rather than implied (ADR-002 §7).
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists and is already
# adopted by modules/parts/capsules.nix → using its shape. Grepped the pinned
# flake-parts `modules/` for a per-output nixpkgs-config seam
# (`allowUnfree|nixpkgsConfig|_module.args.pkgs`): the only mechanism is
# `perSystem._module.args.pkgs`, which is FLAKE-WIDE per system — the satellite
# could use it because its flake contained nothing else. Here it would widen
# every other output's pkgs, so the narrowed instance is imported locally
# instead; that is nixpkgs' own documented entry point, not a bespoke one.
{
  inputs,
  lib,
  ...
}:
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "tart-vms" ];

  # The RAW seam, for the path-identity reason in §1 above. `darwin` is
  # nix-darwin's own `_class` string, so these are accepted anywhere a
  # nix-darwin module is.
  capsuleModules.darwin = {
    # tart.githubRunners.* — ephemeral Tart-VM-per-job GitHub runners.
    tart-github-runner = ./github-runner.nix;
    # tart.gitlabRunner.* — declarative gitlab-runner on the same custom
    # executor and the same two-guest slot budget.
    tart-gitlab-runner = ./gitlab-runner.nix;
    # tart.vms.* — the generic guest lifecycle module. No consumer today; see
    # the ./darwin.nix note above.
    tart-vms = ./darwin.nix;
  };

  # The ONE source path an engine module builds itself — modules/shared/home.nix
  # installs the five gitlab-tart slot shims with the HOST's pkgs so
  # ~/.gitlab-runner/config.toml can reference stable
  # /etc/profiles/per-user/<user>/bin/nix-gitlab-tart-* paths. Rationale for the
  # seam existing at all: modules/parts/capsules.nix § The SOURCE seam.
  capsuleSources.tart-vms.gitlab-tart = ./packages/gitlab-tart.nix;

  perSystem =
    { pkgs, system, ... }:
    let
      # DARWIN-ONLY, exactly as the satellite gated it (`systems =
      # [ "aarch64-darwin" ]`): Tart drives Apple's Virtualization.framework and
      # exists on Apple Silicon only.
      #
      # The gate is INSIDE each output, never around the module body — a
      # `perSystem` whose SHAPE depends on `pkgs` is an infinite recursion
      # through `_module.args`. Same reason as the four capsules before this.
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

      # §2 above: the narrowed unfree predicate, scoped to this capsule's own
      # outputs. tart carries FSL and packer BUSL; tart-guest-agent's derivation
      # sets `meta.license.free = false` itself, hence its name in the list too.
      # A FOURTH unfree package arriving via a nixpkgs bump must fail here.
      pkgsTart = import inputs.nixpkgs {
        inherit system;
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "tart"
            "packer"
            "tart-guest-agent"
          ];
      };

      packer-plugin-tart = pkgsTart.callPackage ./packages/packer-plugin-tart.nix { };
      tart-guest-agent = pkgsTart.callPackage ./packages/tart-guest-agent.nix { };
      tart-vm = pkgsTart.callPackage ./packages/tart-vm.nix {
        inherit packer-plugin-tart;
        # Was `? ../templates/vanilla-tahoe.pkr.hcl` in the satellite; a capsule
        # leaf may not reach up, so the entry file passes the sibling down.
        defaultTemplate = ./templates/vanilla-tahoe.pkr.hcl;
      };
      # GitLab: cirruslabs' executor + the slot-shim config printer (the stanza
      # it prints embeds the shim store paths).
      gitlabTart = pkgsTart.callPackage ./packages/gitlab-tart.nix { };
      # The GitHub lane's engine — controller/setup/api/poll. Not a flake
      # package (the module callPackages it with the host's pkgs); built here so
      # every script still gets shellcheck'd on a PR.
      tartRunner = pkgsTart.callPackage ./packages/tart-runner.nix { };

      evalChecks = import ./checks/module-evaluations.nix {
        inherit lib tartRunner;
        pkgs = pkgsTart;
        darwinModule = ./darwin.nix;
        githubRunnerModule = ./github-runner.nix;
        gitlabRunnerModule = ./gitlab-runner.nix;
        slotsModule = ./slots.nix;
      };
    in
    {
      packages = lib.optionalAttrs isDarwin {
        inherit packer-plugin-tart tart-guest-agent tart-vm;
        gitlab-tart-executor = gitlabTart.executor;
        tart-gitlab-print-config = gitlabTart.printConfig;
      };

      checks = lib.optionalAttrs isDarwin {
        tart-vms-packer-template = pkgsTart.callPackage ./checks/packer-template.nix {
          packerPluginTart = packer-plugin-tart;
          template = ./templates/vanilla-tahoe.pkr.hcl;
        };

        tart-vms-darwin-module = evalChecks.darwin-module;
        tart-vms-runner-module = evalChecks.runner-module;
        tart-vms-gitlab-runner-module = evalChecks.gitlab-runner-module;
        tart-vms-state-dir = evalChecks.state-dir;
        # The kill-switch gate (ADR-002 §2 anatomy): all four modules, ZERO
        # configuration, MUST contribute nothing — they are in mkDarwin's base
        # list, so anything they leak lands on every composition in the fleet.
        tart-vms-inert = evalChecks.inert;

        # The satellite's five BUILD checks in one derivation. Building each is
        # what runs shellcheck over its `writeShellApplication` script.
        tart-vms-packages = pkgsTart.runCommand "tart-vms-packages" { } ''
          for bin in ${tart-vm}/bin/tart-vm \
                     ${tartRunner.controller}/bin/tart-runner-controller \
                     ${gitlabTart.printConfig}/bin/tart-gitlab-print-config; do
            test -x "$bin"
          done
          test -d ${packer-plugin-tart}/libexec/packer/plugins
          test -d ${tart-guest-agent}
          echo ok > "$out"
        '';
      };
    };
}
