# Your host deltas, layered on top of the engine's hosts/macos.nix profile
# (which mkDarwin imports via `hostname = "macos"`). Same module system:
# anything set here MERGES with the engine profile; use lib.mkForce to replace
# an engine value outright.
{ lib, loginName, ... }:
{
  # The engine profile registers self-hosted CI runners for ITS org, keyed to an
  # agenix secret only its operator can decrypt — activation on any other
  # machine fails while this is on.
  services.macosGithubRunner.enable = lib.mkForce false;

  # The engine profile's Gmail-MCP accounts belong to its operator, not you —
  # leaving them in would spawn OAuth prompts for accounts you don't own.
  home-manager.users.${loginName}.services.mcpGateway.gmail.accounts = lib.mkForce [ ];

  # Homebrew apps for THIS Mac. These MERGE with the engine's list; wrap either
  # list attribute in lib.mkForce to replace the engine's set instead.
  homebrew = {
    brews = [
      "gh"
    ];
    casks = [
      "firefox"
      "rectangle"
    ];
  };
}
