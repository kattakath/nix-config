# nix-darwin system module — macOS-specific system preferences.
# This is "system logic" for the Mac; user logic stays in modules/shared.
{
  config,
  pkgs,
  userName,
  ...
}:

let
  # Screenshots land here and are rotated by services.fileRotation below.
  screengrabDir = "${config.users.users.${userName}.home}/Pictures/Screengrab";
in
{
  imports = [
    # Declarative Homebrew (taps/brews/casks) for the Mac.
    ./homebrew.nix
    # Install Homebrew itself at the arch-correct prefix (nix-homebrew).
    ./nix-homebrew.nix
    # Generic per-directory file-rotation LaunchAgents (used for screenshots).
    ./file-rotation.nix
  ];

  # Hourly LaunchAgent that rotates ~/Pictures/Screengrab (>24h → ~/.Trash).
  services.fileRotation.paths = [
    {
      name = "screengrab-rotate";
      path = screengrabDir;
      maxAgeDays = 1;
      action = "trash";
    }
  ];

  # NOTE: hostPlatform is set per-host from the darwinSystem `system` arg (via
  # the mkDarwin helper in flake.nix), NOT hardcoded here — so this shared module
  # serves the aarch64-darwin (macos) Mac.

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
    # user declared in the darwin host profile (hosts/macos.nix).
    primaryUser = userName;

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

      # Save screenshots into the rotated Screengrab dir (not ~/Desktop).
      screencapture = {
        location = screengrabDir;
        type = "png";
        disable-shadow = true;
      };
    };
  };

  # `screencapture` silently reverts to ~/Desktop if its target dir is missing,
  # so guarantee it exists (and is user-owned) at activation. Activation runs as
  # root in current nix-darwin, hence the explicit chown.
  system.activationScripts.postActivation.text = ''
    mkdir -p "${screengrabDir}"
    chown ${userName} "${screengrabDir}"
  '';

  # Window manager placeholder — uncomment and configure when adopted:
  # services.yabai.enable = true;
  # services.skhd.enable = true;

  # Touch ID for sudo — this fleet's sole Mac is Apple Silicon with a sensor.
  security.pam.services.sudo_local.touchIdAuth = true;
}
