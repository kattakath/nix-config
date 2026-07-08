# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. NO incoming traffic: no tunnel, no listening services. (The
# GitHub Actions runner imported below is OUTBOUND-only — it polls GitHub, opens
# no port — so it doesn't break that stance.) Home Manager and the
# nix-vscode-extensions overlay are wired centrally by mkDarwin in flake.nix —
# this file only provides host-specific settings.
#
# First activation (after Determinate Nix is installed, before darwin-rebuild is
# on PATH) — a single line straight from the flake, the darwin analog of
# `nix run .#nixvm` (see flake.nix apps.aarch64-darwin.macos):
#   nix run github:ismailkattakath/nix-config#macos
# Thereafter: darwin-rebuild switch --flake .#macos
{ userName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
    # Self-hosted GitHub Actions runner. Hand-rolled as a launchd daemon because
    # nix-darwin's `services.github-runners` requires `nix.enable = true`, which
    # is incompatible with this host's Determinate Nix (nix.enable = false).
    ../modules/darwin/github-runner.nix
  ];

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };

  # agenix: decrypt secrets/gh-runner-token.age at activation using this Mac's SSH
  # host key (/etc/ssh/ssh_host_ed25519_key, an age identity via SSH). The runner's
  # PAT is owned by `_github-runner` so the launchd daemon (which runs as that
  # user) can read it. Edit the secret with:
  #   agenix -e secrets/gh-runner-token.age   (recipients in secrets/secrets.nix)
  age.secrets."gh-runner-token" = {
    file = ../secrets/gh-runner-token.age;
    owner = "_github-runner";
    mode = "0400";
  };
}
