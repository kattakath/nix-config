# Bridge file: wires the nix-darwin SYSTEM layer to the Home Manager USER layer
# for the "macbook" host. nix-darwin ships a home-manager module that nests a
# standalone-style user profile inside the system rebuild, so a single
# `darwin-rebuild switch --flake .#macbook` provisions both.
{
  home-manager,
  agenix,
  username,
  ...
}:

{
  imports = [
    ../modules/darwin/core.nix
    home-manager.darwinModules.home-manager
  ];

  # Define the human user nix-darwin manages.
  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };

  # Home Manager, as a nix-darwin submodule.
  home-manager = {
    useGlobalPkgs = true; # reuse the system nixpkgs (DRY, one eval)
    useUserPackages = true; # install user packages into /etc/profiles
    extraSpecialArgs = {
      secretsDir = ../secrets;
    };
    users.${username} = {
      imports = [
        ../modules/shared/home.nix
        agenix.homeManagerModules.default
      ];
      home.stateVersion = "24.05";
    };
  };
}
