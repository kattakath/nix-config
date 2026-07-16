# macOS host config for "macos" (Apple Silicon, aarch64-darwin) — the fleet's
# sole client Mac. NO incoming traffic: no tunnel, no listening services. (The
# GitHub Actions runner imported below is OUTBOUND-only — it polls GitHub, opens
# no port — so it doesn't break that stance.) Home Manager and the
# nix-vscode-extensions overlay are wired centrally by mkDarwin in flake.nix —
# this file only provides host-specific settings.
#
# First activation (after Determinate Nix is installed, before darwin-rebuild is
# on PATH) — a single line straight from the flake (the darwin analog of nixpi's
# `nixos-rebuild switch --flake .#nixpi`; see flake.nix apps.aarch64-darwin.macos):
#   nix run github:kattakath/nix-config#macos
# Thereafter: darwin-rebuild switch --flake .#macos
{ userName, ... }:
{
  imports = [
    ../modules/darwin/core.nix
    # On-demand self-hosted `macos` GitHub Actions runner — DISABLED / not
    # auto-started by default now that CI runs on GitHub-hosted runners (see
    # nix-ci.yml), and local aarch64-linux builds use Determinate's native Linux
    # builder (see the macos block in flake.nix). Kept as break-glass infra: a
    # hand-rolled launchd daemon (nix-darwin's services.github-runners needs
    # nix.enable = true, incompatible with Determinate). Enable via
    # services.macosGithubRunner.enable.
    ../modules/darwin/github-runner.nix
  ];

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
