# ---- CAPSULE: cloudflared-connector (ADR-002 wave 3) ------------------------
#
# THE ONLY FILE ANYTHING OUTSIDE THIS DIRECTORY IMPORTS. Absorbed from the
# standalone github:kattakath/nix-cloudflared-connector flake by PLAIN COPY —
# history stays in the archived origin repo, per the operator's decision.
#
# WHAT MOVED, AND WHAT DID NOT:
#   modules/cloudflared-connector.nix -> ./module.nix          (byte-identical)
#   flake.nix's `module-evaluates` check -> ./checks/module-evaluates.nix
#   README.md                          -> ./README.md          (rehomed verbatim
#                                                               but for the Install
#                                                               section, which now
#                                                               describes in-tree use)
#   flake.nix's treefmt block + checks.treefmt  -> DROPPED. nix-config's own
#     treefmt.nix / `checks.formatting` already covers this tree; a capsule
#     carrying a second formatter config would be two sources of truth for one
#     `nix fmt`.
#
# THE CAPSULE INVARIANT, and why it is mechanical rather than a convention:
# nothing in here may reach OUTSIDE this directory by path. That is enforced by
# ast-grep/rules/capsule-must-not-reach-out.yml (`files: modules/features/**`,
# `kind: path_expression`, severity error) riding the existing
# `checks.<system>.ast-grep` gate — so a `../../hosts/nixpi.nix` here is a build
# failure, not a review comment. It is also why ./checks/module-evaluates.nix
# takes `module` as an ARGUMENT instead of importing `../module.nix`: a capsule
# is reached downward from this file, never upward from a leaf.
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists → using it.
# `flake.modules.<class>.<name>` (pinned flake-parts extras/modules.nix:32-73;
# its `apply` stamps `_class = "nixos"` and a `_file` at :22-28) is upstream's
# own registry for "modules published by the flake", which is exactly what a
# capsule is. It is NOT re-exported as a public flake output — see
# modules/parts/touchup.nix for that decision and the one-line path back.
{ inputs, lib, ... }:
{
  # Self-registration. modules/parts/capsules.nix's `capsule-registry` check
  # asserts this list equals `readDir ./modules/features`, so a misnamed entry
  # file cannot silently drop a whole capsule while CI stays green (ADR-002 §4,
  # finding S3).
  capsules = [ "cloudflared-connector" ];

  flake.modules.nixos.cloudflared-connector = ./module.nix;

  perSystem =
    { pkgs, system, ... }:
    {
      # Carried over from the satellite's own `checks`, gated the same way it
      # was there: the fixture is a NixOS system, so the check only exists where
      # the module can actually be built. (The satellite spelled this
      # `lib.elem system linuxSystems`; `isLinux` is the same predicate against
      # this flake's two systems.)
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        cloudflared-connector-module = import ./checks/module-evaluates.nix {
          inherit (inputs) nixpkgs;
          inherit pkgs system;
          module = ./module.nix;
        };
      };
    };
}
