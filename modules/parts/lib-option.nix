# ---- Two flake outputs that MUST be mergeable across files ------------------
#
# flake-parts' `flake` option is freeform, and its freeform type is
# `lazyAttrsOf (types.unique { … } types.raw)` (pinned flake-parts
# modules/flake.nix:14-28). `unique` means ONE definition, in ONE file, or the
# merge fails with "No option has been declared for this flake output
# attribute". That is fine for a genuinely single-owner output (`deploy`,
# `identity`, `templates`) and WRONG for these two:
#
#   flake.lib                   modules/parts/compose.nix contributes the three
#                               builders; modules/parts/terranix.nix contributes
#                               the three renderers. Two files, one attrset.
#   flake.darwinConfigurations  one host today, but the whole point of this wave
#                               is that a future host/capsule can add one
#                               without editing someone else's file.
#
# The fix is upstream's own: declare each as `lazyAttrsOf raw`, copying
# flake-parts' `modules/nixosConfigurations.nix:11` verbatim in shape (that is
# why `nixosConfigurations` needs no declaration here — flake-parts already
# ships exactly this for it, and none for `darwinConfigurations`).
#
# Leaving these undeclared is the single most expensive mistake available in a
# modular flake-parts design: it silently re-creates today's monolith by making
# one file the only legal home for every seam.
{ lib, ... }:
{
  options.flake = {
    lib = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = ''
        The composition API private flakes consume:
        `nix-config.lib.mkDarwin { …; extraHomeModules = [ … ]; }`.
        Contributed to by more than one part, hence `lazyAttrsOf`, not `unique`.
      '';
    };

    darwinConfigurations = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = ''
        Instantiated nix-darwin configurations, used by `darwin-rebuild`.
        Mirrors flake-parts' own `flake.nixosConfigurations`
        (modules/nixosConfigurations.nix:11), which upstream declares and this
        one it does not.
      '';
    };
  };
}
