# Unified user profile — loaded on EVERY machine (macOS, Ubuntu, Pi, container).
# This is the single home of "user logic". Nothing platform-specific belongs here;
# platform branches live in modules/linux and modules/darwin.
# Personal tokens are intentionally NOT managed here. agenix was dropped for
# user secrets (each rotation = a committed .age = version-control churn). On
# macOS the raw env-var tokens live in the login Keychain, exported by the
# host-local ~/.zprofile; login-style tokens use one-time CLI logins
# (gh/hf/docker/claude). agenix now covers only system/cloudflared host secrets.
# See secrets/README.
#
# Deliberately MINIMAL: editor/multiplexer/prompt niceties (nixvim, tmux,
# starship, …) are intentionally NOT managed here — the operator uses VSCode/
# Cursor and prefers a lean, low-noise profile. Add tools only when there's a
# clear cross-host need.
{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [ ../linux/nix-ld.nix ];

  # Make Home-Manager-installed font packages discoverable by applications.
  # Essential on Linux (registers fonts with fontconfig); harmless no-op on macOS.
  fonts.fontconfig.enable = true;

  # Deliberately minimal. CLI tools are NOT managed here — they stay in Homebrew
  # on macOS (see modules/darwin/homebrew.nix); the shared profile carries only
  # cross-host *fonts* plus the program modules below (git/ssh/bash).
  #
  # Fonts: promoted from Homebrew font casks (2026-06-22) so the same Nerd Fonts
  # + Roboto family exist on EVERY host, including NixOS and devcontainers — not
  # just macOS. The cask equivalents were removed from modules/darwin/homebrew.nix.
  # nixpkgs unstable uses the per-font `nerd-fonts.<name>` attrs (the 24.05+
  # restructure; lowercase-hyphenated names) — NOT the old
  # `(nerdfonts.override { fonts = ...; })`. `roboto` is the full Roboto family
  # and covers both font-roboto AND font-roboto-condensed.
  home.packages = with pkgs; [
    # fonts
    nerd-fonts.fira-code
    nerd-fonts.hack
    nerd-fonts.ubuntu
    nerd-fonts.ubuntu-mono # "UbuntuMono Nerd Font" for the devcontainer terminal
    roboto # Roboto family incl. Condensed
  ];

  # ---- Home Manager program modules --------------------------------------------
  programs = {
    # Let Home Manager manage itself.
    home-manager.enable = true;

    git = {
      enable = true;
      settings = {
        user.name = lib.mkDefault "Ismail Kattakath";
        user.email = lib.mkDefault "ismail@kattakath.com";
        init.defaultBranch = "main";
        pull.rebase = true;
        commit.gpgsign = true;
        gpg.format = "ssh";
        user.signingkey = "~/.ssh/id_ed25519.pub";
      };
    };

    ssh = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      matchBlocks = {
        # Reach the NixOS hosts over their Cloudflare Tunnel: ssh routes through
        # `cloudflared access ssh` (no public port; the tunnel forwards to localhost:22).
        "nixbox.kattakath.com" = {
          user = config.home.username;
          identityFile = "~/.ssh/id_ed25519";
          proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
        };
        "nixrpi.kattakath.com" = {
          user = config.home.username;
          identityFile = "~/.ssh/id_ed25519";
          proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
        };
      };
    };

    # A login shell is required for `home-manager switch` to wire session vars.
    bash = {
      enable = true;
    };
  };
}
