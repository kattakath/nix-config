# Bridge file for the "nixtel" host — an x86_64-darwin (Intel) Mac.
#
# CONFIG-ONLY / CI-eval today: nixtel is not activated on a real machine yet, so
# it only needs to EVALUATE on the x86_64-darwin path. It mirrors hosts/nixcon.nix
# (the same shared darwin core + Home Manager profile); the host's platform is set
# by the mkDarwin helper in flake.nix from the `system` arg, so nothing here is
# arch-hardcoded.
#
# For a REAL Intel Mac later: Homebrew's prefix is /usr/local (Apple Silicon uses
# /opt/homebrew) — a nix-darwin activation detail, not an eval concern; and add
# any Intel-specific hardware/state as needed.
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

  # VS Code Marketplace overlay, built against THIS nixpkgs so extensions honour
  # our unfree allowance (see the same note in hosts/nixcon.nix).
  nixpkgs.overlays = [ nix-vscode-extensions.overlays.default ];

  # Allow unfree (claude-code CLI, vscode, MS marketplace extensions).
  nixpkgs.config.allowUnfree = true;

  # The human user nix-darwin manages.
  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };

  # Home Manager, as a nix-darwin submodule.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${username} = {
      imports = [
        ../modules/shared/home.nix
      ];
      home.stateVersion = "24.05";
    };
  };
}
