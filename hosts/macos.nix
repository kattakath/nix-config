# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. NO incoming traffic: no tunnel, no listening services, no
# self-hosted runner. Home Manager and the nix-vscode-extensions overlay are wired
# centrally by mkDarwin in flake.nix — this file only provides host-specific settings.
#
# First activation (after Determinate Nix is installed, before darwin-rebuild is
# on PATH) — a single line straight from the flake (the darwin analog of nixpi's
# `nixos-rebuild switch --flake .#nixpi`; see flake.nix apps.aarch64-darwin.macos):
#   nix run github:kattakath/nix-config#macos
# Thereafter: darwin-rebuild switch --flake .#macos
{ userName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
  ];

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };
}
