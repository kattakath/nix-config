# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. NO incoming traffic: no tunnel, no listening services. (The
# GitHub Actions runner imported below is OUTBOUND-only — it polls GitHub, opens
# no port — so it doesn't break that stance.) Home Manager and the
# nix-vscode-extensions overlay are wired centrally by mkDarwin in flake.nix —
# this file only provides host-specific settings.
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

  # sops-nix: decrypt secrets/macos.yaml at activation using this Mac's SSH host
  # key (/etc/ssh/ssh_host_ed25519_key, via ssh-to-age). The runner's PAT
  # (`gh-runner-token`) is owned by `_github-runner` so the launchd daemon (which
  # runs as that user) can read it. Edit the secret with:
  #   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/macos.yaml
  sops = {
    defaultSopsFile = ../secrets/macos.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    secrets."gh-runner-token" = {
      owner = "_github-runner";
      mode = "0400";
    };
  };
}
