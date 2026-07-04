# Bridge file for the "nixtel" host — a real Apple Intel Mac (x86_64-darwin).
#
# Mirrors hosts/nixcon.nix (the same shared darwin core + Home Manager profile).
# The host platform is set by the mkDarwin helper in flake.nix from the `system`
# arg, so nothing here is arch-hardcoded. Homebrew installs to /usr/local
# automatically (nix-homebrew keys the prefix off the host platform), and Touch ID
# is gated off in modules/darwin/core.nix (this machine has no sensor).
# Activate on the machine with: darwin-rebuild switch --flake .#nixtel
{
  home-manager,
  userName,
  domainName,
  fullName,
  handleName,
  nix-vscode-extensions,
  ...
}:

{
  imports = [
    ../modules/darwin/core.nix
    home-manager.darwinModules.home-manager
  ];

  # VS Code Marketplace overlay, built against THIS nixpkgs so extensions honour
  # our unfree allowance (see the same note in hosts/nixcon.nix).
  nixpkgs.overlays = [ nix-vscode-extensions.overlays.default ];

  # Allow unfree (claude-code CLI, vscode, MS marketplace extensions).
  nixpkgs.config.allowUnfree = true;

  # The human user nix-darwin manages.
  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };

  # Home Manager, as a nix-darwin submodule.
  home-manager = {
    extraSpecialArgs = {
      inherit
        userName
        domainName
        fullName
        handleName
        ;
    }; # thread identity into HM modules
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${userName} = {
      imports = [
        ../modules/shared/home.nix
      ];
      home.stateVersion = "24.05";
    };
  };
}
