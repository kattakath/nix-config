# ---- CAPSULE: media-cli (ADR-002 wave 5) ------------------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-media-cli flake by PLAIN COPY — history stays
# in the archived origin repo, per the operator's decision.
#
# The LARGEST capsule (4,559 lines, ~1,300 of them the queue alone) and the last
# of the seven satellites but one. Its live surface is narrow in nix-config's
# terms — one option set in modules/shared/home.nix — and zero in nix-personal's,
# which is why a tree this big can move in one wave without moving a host drv.
#
# ---- THE THREE THINGS THAT ARE LOAD-BEARING HERE ----------------------------
#
# 1. `package-graph.nix` IS ONE COPY, CALLED TWICE. It is imported by this file
#    (for the checks) and by ./module.nix (for `home.packages`), and that is the
#    whole reason the file exists: before it, the flake and the module each
#    spelled the 11-node graph out, `defaultModel` existed on the module side
#    alone, and the two `media-describe` derivations were quietly different. Its
#    own header records that. Do not re-inline it into either caller.
#
# 2. THE INNER `nix-<name>` WRAPPER STAYS. ./module.nix builds its own
#    `pkgs.writeShellScriptBin "nix-media-queue"` and sets `ProgramArguments`
#    itself rather than taking home-manager's `/bin/sh -c "wait4path … && exec"`
#    shape. That is not style: `.claude/rules/launchd-naming.md` measured that an
#    adhoc-signed /nix/store arg0 may READ the TCC-protected user folders while
#    Apple's own /bin/sh gets EPERM, so a `/bin/sh` arg0 means the worker runs,
#    logs nothing useful, and quietly does no work on the very folders it exists
#    for. `checks.media-cli-module` asserts the arg0 is both `nix-*` AND a store
#    path, which is what keeps "module-evaluates" a meaningful gate rather than a
#    tautology. (It also means this module needs no vendored launchd fork — it
#    works against UPSTREAM home-manager, independently of
#    modules/shared/hm-launchd/.)
#
# 3. THE launchd COMMENT BLOCK IN ./module.nix IS THE ARGUMENT, NOT DECORATION.
#    The `QueueDirectories` / `ProcessType` / `KeepAlive` / `RunAtLoad` /
#    `StartInterval` table at the top of that file is the record that EVERY queue
#    mechanism here is launchd's own — there is no scheduler, no polling loop and
#    no supervision daemon of ours anywhere in 1,300 lines of queue. It is the
#    motto's "Community Legos" half, measured and written down, and it is what
#    answers "why did you hand-roll a job queue" with "we did not". It is carried
#    over VERBATIM and must stay that way.
#
# ---- WHAT MOVED, AND WHAT DID NOT -------------------------------------------
#   modules/media-cli.nix  -> ./module.nix   (byte-identical but for the
#                                             `../lib/packages.nix` ->
#                                             `./package-graph.nix` import the
#                                             capsule invariant forces)
#   lib/packages.nix       -> ./package-graph.nix — moved to the capsule ROOT,
#     NOT kept under `lib/`. A capsule may not use a parent-directory path
#     literal anywhere, even one that stays inside the capsule
#     (ast-grep/rules/capsule-must-not-reach-out.yml, severity error), so from
#     `lib/` all eleven `callPackage` lines would have had to be `../packages/`.
#     The flattening is what makes them `./packages/` — same functions, same
#     store paths, same drvs. tart-vms flattened its four modules for the same
#     reason.
#   packages/*.nix (11)    -> ./packages/ VERBATIM. Not one byte: every one of
#     them is a `writeShellApplication`/`writeShellScriptBin` whose script text
#     IS the derivation, so an edit here is a changed drv, a changed
#     `home.packages`, and a changed `darwin-system` — which is precisely what
#     this wave's acceptance test forbids.
#   checks/queue-state-machine.nix -> ./checks/ verbatim but for its signature:
#     `../packages/media-queue.nix` became a `queueSrc` ARGUMENT this file
#     supplies. Same capsule invariant, same fix the other capsules used for
#     their `module` argument.
#   flake.nix's 3 inline EVAL checks -> ./checks/module-evaluations.nix, bodies
#     and comments verbatim, + a fourth: the kill-switch `inert` gate, which the
#     satellite did not need and this repo does (see that file).
#   flake.nix's `packages` + `apps`  -> NOT re-published. See the next block.
#   flake.nix's `formatter` + nixConfig -> DROPPED. This repo's treefmt.nix and
#     modules/shared/nix-cache.nix already own both, once.
#   .github/, CODE_OF_CONDUCT.md, CONTRIBUTING.md, SECURITY.md, LICENSE ->
#     NOT copied. Collapsing seven CI pipelines into one is the point of
#     ADR-002; this repo has its own governance files and its own MIT LICENSE.
#   README.md -> ./README.md, rehomed next to the code it describes.
#
# ---- THE UN-PUBLISHING IS A DECISION, AND HERE IT IS (ADR-002 §7.3) ---------
# The satellite exported all 11 packages and 9 apps. This capsule exports
# NEITHER, and that is a deliberate narrowing rather than an oversight:
#
#   * nix-config has NEVER carried a media package or app. Every one of these
#     CLIs reaches the Mac through ./module.nix's `home.packages`, built with
#     the HOST's pkgs — publishing a second, perSystem-pkgs copy would add 11
#     rows to `nix flake show` that nothing in the fleet consumes.
#   * The shellcheck coverage the satellite's CI got from BUILDING them is NOT
#     lost — `media-cli-packages` below builds all eleven in one derivation.
#     That is the same call keychain-secrets made, for the reason ADR-002 §7.4
#     names "the highest-cost silent loss available": nix-config's darwin CI leg
#     builds `.#checks.<system>` and none of its packages.
#   * The path back is one line each (`packages = lib.optionalAttrs isDarwin
#     graph;`), if a `nix run .#media-describe` ever has a caller.
#
# UPSTREAM FIRST → grepped the pinned home-manager for a launchd `arg0` seam
# (`ProgramArguments|waitForNixStore|wait4path` over modules/launchd/): the only
# knob is `waitForNixStore` (modules/launchd/default.nix:47-52), which upstream
# itself documents as the trade "appear[s] under its own name, rather than as
# 'sh' … but the agent will fail to start if launchd runs it before the Nix store
# is mounted" — i.e. it drops wait4path entirely rather than moving it inside a
# named wrapper. No option produces a `nix-*` arg0 that still waits, so
# ./module.nix's own wrapper stands → custom, because upstream has no such
# option. (That is also exactly what modules/shared/hm-launchd/ exists for on the
# ENGINE side; this capsule cannot reach it and does not need to.)
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists and is already
# adopted by modules/parts/capsules.nix → using its shape.
{ inputs, lib, ... }:
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "media-cli" ];

  # THE RAW SEAM, not `flake.modules.homeManager.…` — and here the measurement
  # that forced it is not hypothetical. `flake.modules`' element type is
  # `deferredModule`, whose merge wraps every definition in `{ imports = [ … ] }`
  # (modules/parts/capsules.nix § The RAW module seam). That wrapper changes
  # home-manager's module-collection order, hence the ORDER of `home.packages`,
  # hence `home-manager-path`'s buildEnv, hence the `darwin-system` drv. This
  # module contributes the single largest `home.packages` block on the Mac
  # (media-toolkit + media-queue + exiftool + auge + rclip), so it is the most
  # exposed of any capsule to that reordering.
  capsuleModules.homeManager.media-cli = ./module.nix;

  perSystem =
    { pkgs, ... }:
    let
      # DARWIN-ONLY, exactly as the satellite gated it (`system ==
      # "aarch64-darwin"` against its three systems). That gate is real, not
      # defensive: only media-extract-audio is portable — media-fix-extension
      # calls /usr/bin/mdls and BSD `stat -f`, media-transcode adds
      # /usr/bin/SetFile and ~/.Trash, media-describe shells out to /usr/bin/sips
      # and Apple's Vision framework, the Services are Automator bundles, and the
      # queue is launchd end to end.
      #
      # The gate is INSIDE each output, never around the module body — a
      # `perSystem` whose SHAPE depends on `pkgs` is an infinite recursion
      # through `_module.args`. Same reason as the five capsules before this.
      isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

      # ONE graph, shared with ./module.nix. Called with neither knob here, so
      # each package gets its own default — which is what the satellite's
      # `packages` output did, and what keeps these check derivations equal to
      # the ones a bare `media-describe` would build.
      graph = import ./package-graph.nix { inherit pkgs; };

      evalChecks = import ./checks/module-evaluations.nix {
        inherit pkgs;
        inherit (inputs) home-manager;
        module = ./module.nix;
        packageGraph = ./package-graph.nix;
      };
    in
    {
      checks = lib.optionalAttrs isDarwin {
        media-cli-module = evalChecks.module-evaluates;
        media-cli-host-reaches-worker = evalChecks.host-reaches-worker;
        media-cli-host-is-baked = evalChecks.host-is-baked;
        # The kill-switch gate — this module is imported by EVERY host's home
        # profile and gated to the Mac by one option, so "off" must contribute
        # nothing at all.
        media-cli-inert = evalChecks.inert;

        # The only check here that EXECUTES the queue rather than evaluating or
        # building it — see ./checks/queue-state-machine.nix for what the build
        # sandbox can and cannot run, and for the two state-machine paths
        # (/bin/ps: pause, adoption) it deliberately does not claim to cover.
        media-cli-queue-state-machine = import ./checks/queue-state-machine.nix {
          inherit pkgs;
          queueSrc = ./packages/media-queue.nix;
        };

        # The satellite's eleven package outputs, folded into ONE derivation
        # that depends on all of them. Not ceremony: each is a
        # `writeShellApplication`, and BUILDING it is what runs shellcheck over
        # its script. See the un-publishing block in this file's header.
        #
        # `media-quick-actions` is a directory of .workflow bundles rather than a
        # bin, so it is depended on by path; the rest are checked for their
        # executable.
        media-cli-packages = pkgs.runCommand "media-cli-packages" { } ''
          for bin in ${graph.media-fix-extension}/bin/media-fix-extension \
                     ${graph.media-transcode}/bin/media-transcode \
                     ${graph.media-extract-audio}/bin/media-extract-audio \
                     ${graph.media-fix}/bin/media-fix \
                     ${graph.media-describe}/bin/media-describe \
                     ${graph.media-queue}/bin/media-worker \
                     ${graph.media}/bin/media \
                     ${graph.fidelity-enhance}/bin/fidelity-enhance \
                     ${graph.obs-fb-setup}/bin/obs-fb-setup; do
            test -x "$bin"
          done
          test -d ${graph.media-toolkit}
          test -d ${graph.media-quick-actions}
          echo ok > "$out"
        '';
      };
    };
}
