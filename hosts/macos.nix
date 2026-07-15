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
#   nix run github:kattakath/nix-config#macos
# Thereafter: darwin-rebuild switch --flake .#macos
{ userName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
    # On-demand self-hosted GitHub Actions runners — both DISABLED / not-auto-started
    # by default now that CI runs on GitHub-hosted runners (see nix-ci.yml). Kept as
    # break-glass / local-builder infrastructure.
    #   macos runner: hand-rolled launchd daemon (nix-darwin's services.github-runners
    #     needs nix.enable = true, incompatible with this host's Determinate Nix).
    #     Disabled by default; enable via services.macosGithubRunner.enable.
    ../modules/darwin/github-runner.nix
    #   nixvm: the aarch64-linux QEMU/HVF guest. autoStart defaults false, so it is an
    #     on-demand local builder (kickstart it when needed) — see the module.
    ../modules/darwin/nixvm-qemu.nix
  ];

  # Define the nixvm daemon (8 vCPU / 16 GiB of the M3 Pro's 12 cores / 36 GiB — NOT
  # 12 vCPU, or the guest would size `nix build -j` to match and starve macOS).
  # autoStart defaults false: on-demand only, brought up with `launchctl kickstart`.
  services.nixvm-qemu.enable = true;

  nixpkgs.config.allowUnfree = true;

  users.users.${userName} = {
    name = userName;
    home = "/Users/${userName}";
  };

  # NOTE: the `macos` runner's agenix secret (gh-runner-token) is declared BY the
  # runner module under its enable guard (modules/darwin/github-runner.nix), so it
  # only materialises when that on-demand runner is enabled — no dangling
  # `_github-runner`-owned secret while it is disabled. Edit it with:
  #   agenix -e secrets/gh-runner-token.age   (recipients in secrets/secrets.nix)
}
