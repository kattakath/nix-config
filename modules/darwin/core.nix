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

  # NOTE: no `nix.settings.experimental-features` here. This host runs Determinate
  # Nix (determinateNix.enable in flake.nix → nix.enable = false), which enables
  # flakes + nix-command by default and OWNS /etc/nix/nix.conf — the `nix.*`
  # options are unavailable once Determinate manages the daemon.

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
    # Deliberately a CURATED slice, not exhaustive. nix-darwin models far more of
    # the `defaults` surface than is set here — see docs/macos-settings-surface.md
    # for the full available map and the TCC/FileVault boundaries.
    defaults = {
      dock = {
        autohide = true;
        orientation = "right";
        show-recents = false;
        tilesize = 24;
        # Don't reorder Spaces by most-recent-use — a stable Mission Control
        # layout keeps keyboard space-switching predictable.
        mru-spaces = false;
        # Minimize windows into their app's Dock icon (tidier Dock).
        minimize-to-application = true;
        # The little dot under running apps.
        show-process-indicators = true;
        # Hot corners are all left unset (null = system default). To assign one,
        # set the relevant wvous-<pos>-corner (e.g. wvous-bl-corner = 1; disables
        # the bottom-left corner; 2 = Mission Control, 4 = Desktop, 5 = screensaver).
      };

      finder = {
        AppleShowAllExtensions = true;
        FXPreferredViewStyle = "Nlsv"; # list view
        # Show the path bar + status bar, and the full POSIX path in the title.
        ShowPathbar = true;
        ShowStatusBar = true;
        _FXShowPosixPathInTitle = true;
        # Sort folders before files.
        _FXSortFoldersFirst = true;
        # Default new-window/search scope to the current folder, not "This Mac".
        FXDefaultSearchScope = "SCcf";
        # No nag dialog when changing a file's extension.
        FXEnableExtensionChangeWarning = false;
      };

      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
        KeyRepeat = 2;
        InitialKeyRepeat = 15;
        # Key REPEAT on press-and-hold instead of the accent picker — needed for
        # held-key navigation in editors (vim motions, arrow repeat).
        ApplePressAndHoldEnabled = false;
        # Full keyboard access: Tab reaches EVERY control in dialogs, not just
        # text fields and lists.
        AppleKeyboardUIMode = 3;
        # Turn off the "smart" text substitutions that corrupt code and prose.
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticDashSubstitutionEnabled = false;
        NSAutomaticPeriodSubstitutionEnabled = false;
        NSAutomaticQuoteSubstitutionEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        # Expanded save/print panels by default.
        NSNavPanelExpandedStateForSaveMode = true;
        NSNavPanelExpandedStateForSaveMode2 = true;
      };

      # Tap-to-click on the trackpad.
      trackpad.Clicking = true;

      # Require the account password immediately when the screen locks / the
      # screensaver starts (no grace window).
      screensaver = {
        askForPassword = true;
        askForPasswordDelay = 0;
      };

      # No guest account on a single-operator client Mac.
      loginwindow.GuestEnabled = false;

      # Save screenshots into the rotated Screengrab dir (not ~/Desktop).
      screencapture = {
        location = screengrabDir;
        type = "png";
        disable-shadow = true;
      };
    };

    # Keyboard remapping is available (system.keyboard.*) but intentionally left
    # at defaults — the operator has no standing Caps-Lock remap. To adopt one:
    #   keyboard = {
    #     enableKeyMapping = true;
    #     remapCapsLockToControl = true;
    #   };
  };

  # Application firewall ON, with stealth mode — reinforces this client Mac's
  # "NO incoming traffic" posture (hosts/macos.nix): drop unsolicited inbound
  # connections and stay silent to port scans / ICMP probes. (nix-darwin retired
  # the old `system.defaults.alf.*` in favour of `networking.applicationFirewall.*`.)
  networking.applicationFirewall = {
    enable = true;
    enableStealthMode = true;
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
