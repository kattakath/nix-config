# ---- One flake output that MUST be mergeable across files -------------------
#
# flake-parts' `flake` option is freeform, and its freeform type is
# `lazyAttrsOf (types.unique { … } types.raw)` (pinned flake-parts
# modules/flake.nix:14-28). `unique` means ONE definition, in ONE file, or the
# merge fails with "No option has been declared for this flake output
# attribute". That is fine for a genuinely single-owner output (`deploy`,
# `identity`, `templates`) and WRONG for these two:
#
#   flake.lib                   modules/parts/compose.nix contributes the
#                               builders; modules/parts/terranix.nix contributes
#                               its renderer. Two files, one attrset.
#
# The fix is upstream's own: declare it as `lazyAttrsOf raw`, copying
# flake-parts' `modules/nixosConfigurations.nix:11` verbatim in shape. Nothing
# else is declared here: flake-parts ships that for `nixosConfigurations`, and
# `darwinConfigurations` is left undeclared — nix-darwin ships a flake-parts module
# for it (pinned nix-darwin flake-module.nix:6-10, `flakeModules.default` at
# nix-darwin/flake.nix:59) but this repo does not import it; modules/parts/hosts.nix
# is its only definer. A second declaration
# here was a duplicate — removed 2026-09-13.
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
  };
}
