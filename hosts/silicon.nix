# Bridge file: wires the nix-darwin SYSTEM layer to the Home Manager USER layer
# for the "silicon" host. nix-darwin ships a home-manager module that nests a
# standalone-style user profile inside the system rebuild, so a single
# `darwin-rebuild switch --flake .#silicon` provisions both.
{
  home-manager,
  username,
  nix-vscode-extensions,
  ...
}:

{
  imports = [
    ../modules/darwin/core.nix
    home-manager.darwinModules.home-manager
  ];

  # Apply the nix-vscode-extensions overlay so the VS Code Marketplace mirror is
  # available as `pkgs.vscode-marketplace.*` — built against THIS nixpkgs, which
  # is what makes the extensions honour our unfree allowance. (The input's
  # `.extensions.<system>` output instead uses its own nixpkgs with default
  # config and would ignore our allowUnfree — hence the overlay.)
  nixpkgs.overlays = [ nix-vscode-extensions.overlays.default ];

  # Allow unfree packages. Covers the `claude-code` CLI (shared HM profile), the
  # `vscode` editor, and the marketplace extensions (several MS-proprietary ones
  # realize as unfree `vscode-extension-*`). Set at the system level because Home
  # Manager runs with useGlobalPkgs and inherits this nixpkgs.
  nixpkgs.config.allowUnfree = true;

  # Define the human user nix-darwin manages.
  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };

  # Home Manager, as a nix-darwin submodule.
  home-manager = {
    useGlobalPkgs = true; # reuse the system nixpkgs (DRY, one eval)
    useUserPackages = true; # install user packages into /etc/profiles
    users.${username} = {
      imports = [
        ../modules/shared/home.nix
      ];
      home.stateVersion = "24.05";
    };
  };
}
