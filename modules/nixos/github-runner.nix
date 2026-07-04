# GitHub Actions self-hosted runner — ephemeral, per-job, token-authenticated.
#
# WHY NOT `services.github-runner` (singular)? The singular module is the legacy
# single-runner form. This module uses `services.github-runners` (plural, attrsOf
# submodule) which is the current upstream NixOS API and supports multiple runners
# on one host.
#
# TOKEN HANDLING: the runner token is a fine-grained PAT (`github_pat_…`).
# It is stored in an agenix secret (`nixarm-github-runner-token.age`, one raw
# token line — NO `KEY=VALUE` wrapper) and passed to the runner config script
# via `tokenFile`. `tokenType = "access"` forces the `--pat` flag; `"auto"`
# would also work for `github_pat_` prefix but explicit is safer.
#
# NO-OP SAFE: this module is imported for ALL NixOS hosts via flake.nix. It only
# activates the runner when the host has declared the
# `age.secrets."nixarm-github-runner-token"` secret (currently only nixarm does).
# Hosts without that secret get no runner and never reference a missing token file.
{
  config,
  lib,
  pkgs,
  handleName,
  ...
}:
let
  secretName = "nixarm-github-runner-token";
  haveSecret = lib.hasAttr secretName config.age.secrets;
in
{
  config = lib.mkIf haveSecret {
    services.github-runners.nixci = {
      enable = true;
      url = "https://github.com/${handleName}/nix-config";
      tokenFile = config.age.secrets.${secretName}.path;
      # "access" passes --pat to the runner config script; correct for any PAT
      # including fine-grained PATs (github_pat_…). Do NOT use "registration" —
      # that is only for the short-lived UI-generated tokens.
      tokenType = "access";
      extraLabels = [
        "nixos"
        "aarch64-linux"
        "nix"
      ];
      # Ephemeral: de-register after one job and restart — clean environment
      # per run, prevents cross-job state leakage.
      ephemeral = true;
      # Replace any stale registration with the same runner name on startup.
      replace = true;
      extraPackages = with pkgs; [
        git
        nix
        cachix
      ];
    };
  };
}
