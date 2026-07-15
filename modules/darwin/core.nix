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

  # Background login launcher: `open -g -j -a <App>` wrapped in a script with a
  # descriptive basename. macOS's Login Items ▸ "Allow in the Background" list
  # names each item by its executable's basename (verified via `sfltool
  # dumpbtm`), so a bare /usr/bin/open agent shows up as a generic,
  # indistinguishable "open". Running a named wrapper instead makes the entry
  # read e.g. "login-maccy". `-g` = background (no focus steal), `-j` = launch
  # hidden (no window; the menu-bar icon is unaffected).
  mkLoginAgent = suffix: appName: {
    serviceConfig = {
      ProgramArguments = [
        "${pkgs.writeShellScriptBin "login-${suffix}" ''
          exec /usr/bin/open -g -j -a "${appName}"
        ''}/bin/login-${suffix}"
      ];
      RunAtLoad = true;
    };
  };

  # ---- Finder "Show View Options" default template (list view) --------------
  # This is the nested dict that Finder's "Use as Defaults" button writes and
  # that governs any folder WITHOUT its own saved (.DS_Store) view state:
  #   • 32px icons, 16pt text, relative dates + icon preview on
  #   • columns: Name, Kind, Tags (identifier "label"), Date Last Opened;
  #     Date Modified / Date Created / Size OFF
  #   • within the Kind grouping, items sort by Date Modified (FXArrangeGroupViewBy)
  # `defaults write` REPLACES the whole key, so IconViewSettings is reproduced
  # verbatim (current values) to avoid wiping icon-view defaults. Both the modern
  # ExtendedListViewSettingsV2 (what Finder reads first) and the legacy
  # ListViewSettings are set so they stay consistent.
  listCol = ascending: identifier: visible: width: {
    inherit
      ascending
      identifier
      visible
      width
      ;
  };
  listViewTop = {
    calculateAllSizes = 0;
    iconSize = 32;
    showIconPreview = 1;
    sortColumn = "dateModified";
    textSize = 16;
    useRelativeDates = 1;
    viewOptionsVersion = 1;
  };
  finderViewSubsettings = {
    ExtendedListViewSettingsV2 = listViewTop // {
      columns = [
        (listCol 1 "name" 1 300)
        (listCol 0 "dateModified" 0 181)
        (listCol 0 "dateCreated" 0 181)
        (listCol 0 "size" 0 97)
        (listCol 1 "kind" 1 115)
        (listCol 1 "label" 1 100) # Tags
        (listCol 1 "version" 0 75)
        (listCol 1 "comments" 0 300)
        (listCol 0 "dateLastOpened" 1 200)
        (listCol 0 "shareOwner" 0 200)
        (listCol 0 "shareLastEditor" 0 200)
      ];
    };
    ListViewSettings = listViewTop // {
      columns = {
        name = {
          ascending = 1;
          index = 0;
          visible = 1;
          width = 300;
        };
        dateModified = {
          ascending = 0;
          index = 1;
          visible = 0;
          width = 181;
        };
        dateCreated = {
          ascending = 0;
          index = 2;
          visible = 0;
          width = 181;
        };
        size = {
          ascending = 0;
          index = 3;
          visible = 0;
          width = 97;
        };
        kind = {
          ascending = 1;
          index = 4;
          visible = 1;
          width = 115;
        };
        label = {
          ascending = 1;
          index = 5;
          visible = 1;
          width = 100;
        };
        version = {
          ascending = 1;
          index = 6;
          visible = 0;
          width = 75;
        };
        comments = {
          ascending = 1;
          index = 7;
          visible = 0;
          width = 300;
        };
        dateLastOpened = {
          ascending = 0;
          index = 8;
          visible = 1;
          width = 200;
        };
      };
    };
    # Icon-view defaults carried through unchanged (colors are plist <real>s).
    IconViewSettings = {
      arrangeBy = "none";
      backgroundColorBlue = 1.0;
      backgroundColorGreen = 1.0;
      backgroundColorRed = 1.0;
      backgroundType = 0;
      gridOffsetX = 0;
      gridOffsetY = 0;
      gridSpacing = 54;
      iconSize = 64;
      labelOnBottom = 1;
      showIconPreview = 1;
      showItemInfo = 0;
      textSize = 12;
      viewOptionsVersion = 1;
    };
  };
  # Finder keeps TWO parallel default-template keys — the modern
  # FK_StandardViewSettings and the legacy StandardViewSettings — and current
  # macOS still honors the legacy one for list-view icon/text size + columns.
  # Setting only FK_ left the old values winning, so set BOTH from one base.
  finderStandardViewSettings = finderViewSubsettings // {
    SettingsType = "FK_StandardViewSettings";
  };
  finderLegacyViewSettings = finderViewSubsettings // {
    SettingsType = "StandardViewSettings";
    # Gallery-view sub-dict exists only in the legacy blob; carried through as-is.
    GalleryViewSettings = {
      arrangeBy = "name";
      iconSize = 48;
      showIconPreview = 1;
      viewOptionsVersion = 1;
    };
  };
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

      # Finder grouping + sort. nix-darwin's typed `finder` options don't model
      # these two keys, so they go through the CustomUserPreferences escape hatch
      # (a raw `defaults write` into com.apple.finder). FXPreferredGroupBy sets the
      # group *headers* (Kind → one section per file type); FXArrangeGroupViewBy
      # sets the *sort order* of items within the arrangement (Date Modified →
      # newest first). Together: "grouped by kind, sorted by date modified".
      # The list-view "Show View Options" default template (32px icons, 16pt
      # text, the Name/Kind/Tags/Date-Last-Opened column set) governs every
      # folder that has no saved .DS_Store view state — see the let binding above.
      CustomUserPreferences."com.apple.finder" = {
        FXPreferredGroupBy = "Kind";
        FXArrangeGroupViewBy = "Date Modified";
        FK_StandardViewSettings = finderStandardViewSettings;
        StandardViewSettings = finderLegacyViewSettings;
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

  # ---- Launch-at-login agents (declarative "Open at Login") ------------------
  # macOS's System Settings > Login Items list is NOT declaratively manageable
  # (it's SMAppService-backed, protected like TCC). The Nix-native equivalent is
  # a launchd user agent with RunAtLoad — version-controlled and wipe-proof. Each
  # runs a NAMED wrapper (mkLoginAgent, above) so the "Allow in the Background"
  # list shows "login-<app>" rather than five indistinguishable "open"s. For each
  # app, turn OFF its OWN "launch at login" toggle so it doesn't self-register.
  # See docs/macos-settings-surface.md.
  #
  # Notes: Maccy is a menu-bar-only agent (LSUIElement) — the flags are just
  # belt-and-suspenders. Docker's own "Start when you sign in" registered the
  # com.docker.helper background item via SMAppService; disabling it there and
  # driving startup here keeps one declarative source (the privileged
  # com.docker.vmnetd system daemon is separate and unaffected). Slack/Mail/
  # Messages are full GUI apps, so `-j` starts them hidden but a Dock icon still
  # shows while running; Mail/Messages resolve by name from /System/Applications.
  # The agent attr names (open-*) are kept as the launchd Labels so the existing
  # "Allow in the Background" toggle state is preserved across this change.
  launchd.user.agents = {
    open-maccy = mkLoginAgent "maccy" "Maccy";
    open-docker = mkLoginAgent "docker" "Docker";
    open-slack = mkLoginAgent "slack" "Slack";
    open-mail = mkLoginAgent "mail" "Mail";
    open-messages = mkLoginAgent "messages" "Messages";
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
