# `local.nixImplementation` on NixOS — "determinate" (default) or "upstream"
# (ADR-018, DECIDED 2026-11-27; rolled out least live host first, nixvm first).
#
# upstream option `determinate.enable` exists → using it: the pinned determinate
# input's modules/nixos.nix declares it (default true) and puts every setting it
# makes — nix.package, the determinate-nixd daemon and socket, the registry —
# behind `mkIf cfg.enable`. Off, the host runs nixpkgs' own `nix.package` with
# NixOS's own nix-daemon, and core.nix's `nix.settings` (flakes on) apply as is.
#
# Unlike darwin, this IS just a rebuild: NixOS owns its nix-daemon either way,
# and there is no separate store volume to mount — no switch script needed.
{ config, lib, ... }:
{
  options.local.nixImplementation = lib.mkOption {
    type = lib.types.enum (import ../_lib/nix-implementations.nix);
    default = "determinate";
    description = "Which Nix implementation runs this NixOS host (ADR-017 / ADR-018).";
  };

  config = {
    determinate.enable = config.local.nixImplementation == "determinate";
    # Determinate's nix.conf set this; upstream defaults to false (see the same
    # line in modules/parts/compose.nix for the darwin lane and why it matters).
    nix.settings.always-allow-substitutes = lib.mkIf (
      config.local.nixImplementation == "upstream"
    ) true;
  };
}
