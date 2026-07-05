# macOS host config for "nixcon" (Apple Silicon, aarch64-darwin).
# Home Manager and the nix-vscode-extensions overlay are wired centrally by
# mkDarwin in flake.nix — this file only provides host-specific settings.
{ userName, ... }:
{
  imports = [ ../modules/darwin/core.nix ];

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };
}
