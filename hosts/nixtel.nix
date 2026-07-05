# macOS host config for "nixtel" (Intel Mac, x86_64-darwin).
# Home Manager and the nix-vscode-extensions overlay are wired centrally by
# mkDarwin in flake.nix — this file only provides host-specific settings.
# Homebrew prefix auto-selects /usr/local (Intel). Touch ID off: no sensor.
{ userName, ... }:
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };
}
