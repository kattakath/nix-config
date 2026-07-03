# nix-darwin system module — macOS-specific system preferences.
# This is "system logic" for the Mac; user logic stays in modules/shared.
{
  pkgs,
  lib,
  username,
  ...
}:

{
  imports = [
    # Declarative Homebrew (taps/brews/casks) for the Mac.
    ./homebrew.nix
    # Install Homebrew itself at the arch-correct prefix (nix-homebrew).
    ./nix-homebrew.nix
    # Hourly LaunchAgent that rotates ~/Pictures/Screengrab (>24h → ~/.Trash).
    ./screengrab-rotate.nix
  ];

  # NOTE: hostPlatform is set per-host from the darwinSystem `system` arg (via
  # the mkDarwin helper in flake.nix), NOT hardcoded here — so this shared module
  # serves both the aarch64-darwin (nixcon) and x86_64-darwin (nixtel) Macs.

  # Enable flakes + the modern CLI for the daemon this config manages.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # System-level packages (distinct from per-user Home Manager packages).
  environment.systemPackages = with pkgs; [
    coreutils
    curl
  ];

  system = {
    # Required by nix-darwin to track incompatible state migrations.
    stateVersion = 5;

    # Required by current nix-darwin whenever any `system.defaults.*` is set:
    # names the user those user-scoped macOS defaults apply to. Matches the
    # user declared in each darwin host profile (hosts/nixcon.nix, hosts/nixtel.nix).
    primaryUser = username;

    # ---- macOS defaults (declarative system preferences) -----------------------
    defaults = {
      dock = {
        autohide = true;
        orientation = "left";
        show-recents = false;
        tilesize = 48;
      };

      finder = {
        AppleShowAllExtensions = true;
        FXPreferredViewStyle = "Nlsv"; # list view
      };

      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
        KeyRepeat = 2;
        InitialKeyRepeat = 15;
      };
    };
  };

  # Enable macOS Remote Login (Apple's built-in sshd) declaratively — no GUI,
  # no Full Disk Access. nix-darwin's services.openssh flips it on via
  # `launchctl enable/bootstrap system/com.openssh.sshd` (deliberately NOT
  # `systemsetup -setremotelogin`, which is TCC/FDA-gated) and is idempotent:
  # activation only acts when Remote Login is currently Off. Required so the
  # boot-time cloudflared connector's `ssh://localhost:22` ingress actually
  # reaches a listening sshd on both nixcon and nixtel.
  services.openssh.enable = true;

  # Window manager placeholder — uncomment and configure when adopted:
  # services.yabai.enable = true;
  # services.skhd.enable = true;

  # Touch ID for sudo — Apple-Silicon laptops only. The Apple Intel Mac
  # (`nixtel`) has no Touch ID sensor, so gate this off there.
  security.pam.services.sudo_local.touchIdAuth = lib.mkIf pkgs.stdenv.hostPlatform.isAarch64 true;
}
