# ---- CAPSULE: firmware-secrets (ADR-002 wave 4) -----------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-firmware-secrets flake by PLAIN COPY — history
# stays in the archived origin repo, per the operator's decision.
#
# WHAT MOVED, AND WHAT DID NOT:
#   modules/firmware-provisioning.nix   -> ./module.nix        (byte-identical)
#   flake.nix's `module-evaluates` check -> ./checks/module-evaluates.nix
#   README.md                           -> ./README.md         (rehomed verbatim
#                                                               but for Install /
#                                                               Planting, which now
#                                                               describe in-tree use)
#   apps/firmware-plant.nix             -> DROPPED. It is a 61-line macOS
#     `cp onto the mounted FAT volume` helper that DUPLICATES this repo's own
#     `packages/nixpi-provision.nix` (the `nixpi-provision` flake app the flashing
#     runbook actually tells the operator to run). Two copies of one procedure is
#     two chances for the planted BASENAMES to drift apart, and the names are
#     exactly what checks.nixpi-firmware-names exists to pin. The fleet has never
#     invoked `#firmware-plant`; absorbing it would import a second, unused
#     provisioning path.
#   examples/pi-cloudflared.nix         -> DROPPED. It was a hand-maintained
#     sketch of a nixpi for strangers; ../../../hosts/nixpi.nix is the real one,
#     evaluated by `nix flake check` on every PR. A stale example in-tree is worse
#     than no example — see the README's "How it is wired here".
#   flake.nix's treefmt block + checks.treefmt -> DROPPED. This repo's own
#     treefmt.nix / `checks.formatting` already covers this tree; a capsule
#     carrying a second formatter config would be two sources of truth for one
#     `nix fmt`.
#
# THE CAPSULE INVARIANT is mechanical, not a convention: nothing in here may
# reach OUTSIDE this directory by path, enforced by
# ast-grep/rules/capsule-must-not-reach-out.yml (`files: modules/features/**`,
# `kind: path_expression`, severity error) riding the existing
# `checks.<system>.ast-grep` gate. That is why ./checks/module-evaluates.nix
# takes `module` as an ARGUMENT instead of importing `../module.nix`.
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists → using it.
# `flake.modules.<class>.<name>` (pinned flake-parts extras/modules.nix:32-73) is
# upstream's own registry for "modules published by the flake". It is NOT
# re-exported as a public flake output — modules/parts/touchup.nix owns that
# decision and the one-line path back.
{ inputs, lib, ... }:
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "firmware-secrets" ];

  flake.modules.nixos.firmware-secrets = ./module.nix;

  perSystem =
    { pkgs, system, ... }:
    {
      # Carried over from the satellite's own `checks`, gated the same way it was
      # there: the fixture is a NixOS system, so the check only exists where the
      # module can actually be built. (The satellite spelled this
      # `system != "aarch64-darwin"` against its three systems; `isLinux` is the
      # same predicate against this flake's two.)
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        firmware-secrets-module = import ./checks/module-evaluates.nix {
          inherit (inputs) nixpkgs;
          inherit pkgs system;
          module = ./module.nix;
        };
      };
    };
}
