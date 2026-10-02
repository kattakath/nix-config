# nix-darwin system module — macOS-specific system preferences.
# This is "system logic" for the Mac; user logic stays in modules/home.
{
  config,
  lib,
  pkgs,
  loginName,
  ...
}:

let
  home = config.users.users.${loginName}.home;

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
    # The local.folders inbox-path seam (unset = macOS system defaults).
    ./user-folders.nix
    # Declarative Homebrew (taps/brews/casks) for the Mac.
    ./homebrew.nix
    # Install Homebrew itself at the arch-correct prefix (nix-homebrew).
    ./nix-homebrew.nix
    # macos: accept Xcode license (and pre-install Xcode.app) before brew bundle.
    ./xcode-license.nix
  ];

  # NOTE: hostPlatform is set per-host from the darwinSystem `system` arg (via
  # the mkDarwin helper in modules/parts/compose.nix), NOT hardcoded here — so this shared module
  # serves any aarch64-darwin host this flake declares.

  # NOTE: no `nix.settings.experimental-features` here. This host runs Determinate
  # Nix (determinateNix.enable in flake.nix → nix.enable = false), which enables
  # flakes + nix-command by default and OWNS /etc/nix/nix.conf — the `nix.*`
  # options are unavailable once Determinate manages the daemon.

  # System-level packages (distinct from per-user Home Manager packages).
  environment.systemPackages = with pkgs; [
    coreutils
    curl
    # `mas` (Mac App Store CLI) is on PATH through programs.mas
    # (modules/darwin/xcode-license.nix; pinned programs/mas.nix:205).
  ];

  system = {
    # Required by nix-darwin to track incompatible state migrations.
    stateVersion = 5;

    # Required by current nix-darwin whenever any `system.defaults.*` is set:
    # names the user those user-scoped macOS defaults apply to. Matches the
    # user declared in the darwin host profile (hosts/macos.nix).
    primaryUser = loginName;

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
        # Show ONLY running apps — the Dock rebuilds from the running set, so
        # nothing is pinned (launch via Spotlight/Raycast instead).
        static-only = true;
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
        # Second half of the Downloads rotation: the hourly agent below only
        # MOVES stale items into ~/.Trash (still on disk, still recoverable);
        # this makes Finder itself erase Trash items after 30 days, so space is
        # actually reclaimed without a manual "Empty Trash".
        FXRemoveOldTrashItems = true;
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

      # Screen captures: deliberately NO location — macOS's own default is
      # ~/Desktop (an unset/missing location falls back there, nix-darwin#1240),
      # and file-rotation-desktop (modules/home/macos-user-agents.nix) sweeps
      # it daily. The location key would
      # cover BOTH ⇧⌘4 screenshots and ⇧⌘5 screen *recordings* — verified
      # empirically; the .mov honors com.apple.screencapture location despite
      # Apple documenting no separate key for recordings. (The macvm guest's
      # shared-inbox override left with that host, 2026-09-05.)
      screencapture = {
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

    # `system.keyboard.*` is deliberately left at defaults — the operator has no
    # standing Caps-Lock (or any other) remap.
  };

  # Application firewall ON, with stealth mode — reinforces this client Mac's
  # "NO incoming traffic" posture (hosts/macos.nix): drop unsolicited inbound
  # connections and stay silent to port scans / ICMP probes. (nix-darwin retired
  # the old `system.defaults.alf.*` in favour of `networking.applicationFirewall.*`.)
  networking.applicationFirewall = {
    enable = true;
    enableStealthMode = true;
  };

  # ---- GUI PATH: let launchd-started apps see the Nix profiles ---------------
  # A Finder/Dock-launched .app inherits **launchd's** environment, not the
  # shell's: nix-darwin exports PATH only via /etc/zshenv → set-environment, so
  # a GUI app sees just /usr/bin:/bin:/usr/sbin:/sbin and cannot find any Nix
  # binary. Symptom: a GUI tool that shells out to a CLI reports it "not found
  # on your PATH" while `which` resolves it fine in the terminal.
  #
  # `launchd.user.envVariables` is nix-darwin's own option for this — it emits
  # `launchctl setenv` at activation (modules/system/launchd.nix), which is the
  # standard macOS fix. Do NOT hand-roll ~/.local/bin shims per tool.
  #
  # $HOME/$USER must be substituted at eval: launchd does not expand them, and
  # nix-darwin runs the setenv under `sudo --user=`, where a bare $USER would
  # expand to root instead (nix-darwin#406). Values are derived from
  # identityArgs, never a hardcoded home path.
  #
  # Applies to apps started AFTER activation — quit and relaunch a running app.
  launchd.user.envVariables.PATH =
    lib.replaceStrings [ "$HOME" "$USER" ] [ home loginName ]
      config.environment.systemPath;

  # BASH_ENV — close the chicken-and-egg in the Keychain secret loader.
  #
  # Non-interactive bash reads exactly one startup file: $BASH_ENV. But that
  # only helps if BASH_ENV is ALREADY in the environment. `.zshenv` seeds it and
  # the loader re-exports it forward, so anything descended from a zsh is fine —
  # while a bash spawned by a GUI app or a launchd job starts with neither, and
  # silently gets no secrets. That is the gap named in
  # docs/secrets-and-keychain.md § the `$BASH_ENV` gap.
  #
  # ✅ upstream option nix-darwin.launchd.user.envVariables exists → using it
  # (pinned nix-darwin modules/launchd/default.nix:125; it emits `launchctl
  # setenv` at activation via modules/system/launchd.nix). Same option, same
  # $HOME-substitution reasoning as the PATH above.
  #
  # The VALUE is a path, not a secret, so this does not touch the store
  # invariant that no secret — not even a key NAME — reaches /nix/store or git.
  # Derived from the keychain-secrets module rather than restated, so the two
  # cannot drift.
  launchd.user.envVariables.BASH_ENV = "${home}/${
    config.home-manager.users.${loginName}.local.keychainSecrets.loaderRelPath
  }";

  system.activationScripts.postActivation.text = lib.mkIf (config.networking.hostName == "macos") ''
    # Propagate the GUI PATH (see § GUI PATH above) to Dock-launched apps.
    # macOS gives a launched app the LAUNCHING process's environment, so an
    # app opened from the Dock inherits Dock's snapshot — not the current
    # launchd value. nix-darwin restarts Dock in activationScripts.defaults,
    # which runs BEFORE activationScripts.userLaunchd emits `launchctl
    # setenv` (see the generated activate script: Dock restart ~line 1377,
    # setenv ~line 1481), so Dock always holds the PREVIOUS environment and
    # every Dock-launched app misses the fix. postActivation is the last
    # hook, hence the only place this can be corrected.
    #
    # grepped nix-darwin/modules for `killall Dock`/`killall cfprefsd` —
    # ONE hit, and it is the problem rather than the solution:
    # modules/system/defaults-write.nix:156 does
    # `killall -qu <primaryUser> Dock || true`, gated at :154 on
    # `length dock > 0` (always satisfied here) and emitted from
    # activationScripts.defaults — which activation-scripts.nix:126 orders
    # BEFORE userLaunchd's setenv at :129. So upstream already restarts the
    # Dock, just too early to see the new environment, and exposes no
    # ordering control and no separate GUI-env refresh to fix that with.
    # Hence the restart here, after the setenv. (An earlier version of this
    # comment claimed zero hits — corrected 2026-09-06; it contradicted the
    # ordering argument three lines above it.)
    #
    # Stamped so a no-op activation does not bounce the Dock: only restart
    # when the value actually changed. The stamp lives in /run, which
    # nix-darwin recreates at boot, so a reboot re-arms it once.
    gui_path_stamp=/run/nix-darwin-gui-path-stamp
    gui_path_want=$(sudo --user=${loginName} -- launchctl getenv PATH || true)
    if [ -n "$gui_path_want" ] \
      && [ "$(cat "$gui_path_stamp" 2>/dev/null)" != "$gui_path_want" ]; then
      echo "refreshing Dock so GUI apps inherit the new PATH..." >&2
      killall Dock 2>/dev/null || true
      printf '%s' "$gui_path_want" > "$gui_path_stamp"
    fi
  '';

  # Touch ID for sudo — this fleet's sole Mac is Apple Silicon with a sensor.
  security.pam.services.sudo_local.touchIdAuth = true;
}
