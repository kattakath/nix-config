# nix-darwin system module — macOS-specific system preferences.
# This is "system logic" for the Mac; user logic stays in modules/shared.
{ pkgs, username, ... }:

{
  imports = [
    # Declarative Homebrew (taps/brews/casks) for the Mac.
    ./homebrew.nix
    # Hourly LaunchAgent that rotates ~/Pictures/Screengrab (>24h → ~/.Trash).
    ./screengrab-rotate.nix
  ];

  # The platform this system configuration targets.
  nixpkgs.hostPlatform = "aarch64-darwin";

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
    # user declared in hosts/m3pro.nix.
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

  # Window manager placeholder — uncomment and configure when adopted:
  # services.yabai.enable = true;
  # services.skhd.enable = true;

  # Use Touch ID for sudo (quality-of-life on Apple Silicon laptops).
  security.pam.services.sudo_local.touchIdAuth = true;
}
