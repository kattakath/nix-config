# Unified user profile — loaded on EVERY machine (macOS, Ubuntu, Pi, container).
# This is the single home of "user logic". Nothing platform-specific belongs here;
# platform branches live in modules/linux and modules/darwin.
# Personal tokens are intentionally NOT managed here. agenix was dropped for
# user secrets (each rotation = a committed .age = version-control churn). On
# macOS the raw env-var tokens live in the login Keychain, exported by the
# host-local ~/.zprofile; login-style tokens use one-time CLI logins
# (gh/hf/docker/claude). agenix now covers only system/cloudflared host secrets.
# See secrets/README.
{
  pkgs,
  lib,
  config,
  ...
}:
{
  imports = [ ../linux/nix-ld.nix ];

  # Baseline toolset present on all hosts. git / tmux / neovim / ripgrep are
  # NOT listed here — each is installed by its `programs.*` module below, and
  # listing it twice collides on /bin/<tool> in the Home Manager buildEnv.
  # curl is omitted — covered by system packages on all hosts (nixos/core.nix,
  # darwin/core.nix); including it here would add a redundant user-profile copy.
  home.packages = with pkgs; [
    fd
    jq
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

    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      withRuby = false;
      withPython3 = false;
    };

    tmux = {
      enable = true;
      baseIndex = 1;
      keyMode = "vi";
      terminal = "tmux-256color";
    };

    ripgrep.enable = true;

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
