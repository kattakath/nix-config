# nix-darwin system module — macOS-specific system preferences.
# This is "system logic" for the Mac; user logic stays in modules/shared.
{
  config,
  lib,
  pkgs,
  loginName,
  domainName,
  ...
}:

let
  home = config.users.users.${loginName}.home;
  # Screenshots land here and are rotated hourly by the launchd agent below.
  screengrabDir = "${home}/Pictures/Screengrab";
  # Reverse-DNS namespace derived from the fleet domain (kattakath.com → com.kattakath)
  # for the file-rotation launchd label, rather than hardcoding it.
  rdns = lib.concatStringsSep "." (lib.reverseList (lib.splitString "." domainName));

  # BTM names ProgramArguments[0] basename (`sfltool dumpbtm`) — use `nix-<app>`
  # not bare `open`. No custom .app icon: unsigned store paths always show
  # "unidentified developer" without a paid Developer ID.
  #
  # Quiet login launch: `open -g -j` alone is not enough — Slack/Messages/Mail/
  # Docker (and most Electron apps) ignore `-j` and raise a window after init.
  # We still pass -g/-j, then re-hide the process via System Events for ~12s so
  # late window raises never steal focus. Dock / menu-bar icons stay; only the
  # window is suppressed. Needs Accessibility for /usr/bin/osascript (already
  # granted for the MCP gateway — hide is best-effort if missing).
  #
  #   mkNixAgent { suffix = "slack"; app = "Slack"; }
  #   mkNixAgent {
  #     suffix = "docker"; app = "Docker";
  #     processNames = [ "Docker" "Docker Desktop" ];
  #     extraOpenArgs = [ "--unattended" ];
  #   }
  mkNixAgent =
    {
      suffix,
      app,
      # System Events process name(s) to force-hide (may differ from `open -a`).
      processNames ? [ app ],
      # Extra args after `open … --args` (app-specific, e.g. Docker --unattended).
      extraOpenArgs ? [ ],
    }:
    let
      # AppleScript list literal: {"Slack", "Docker Desktop"}
      procList = lib.concatMapStringsSep ", " (n: ''"${n}"'') processNames;
      openArgsShell = lib.concatMapStringsSep " " lib.escapeShellArg extraOpenArgs;
      openCmd =
        if extraOpenArgs == [ ] then
          "/usr/bin/open -g -j -a ${lib.escapeShellArg app}"
        else
          "/usr/bin/open -g -j -a ${lib.escapeShellArg app} --args ${openArgsShell}";
    in
    {
      serviceConfig = {
        ProgramArguments = [
          "${pkgs.writeShellScriptBin "nix-${suffix}" ''
            set -eu
            ${openCmd}
            # Re-hide while the app finishes starting (Electron often shows late).
            hide() {
              /usr/bin/osascript -e '
                tell application "System Events"
                  repeat with procName in {${procList}}
                    try
                      if exists process (procName as text) then
                        set visible of process (procName as text) to false
                      end if
                    end try
                  end repeat
                end tell
              ' 2>/dev/null || true
            }
            i=0
            while [ "$i" -lt 24 ]; do
              hide
              /bin/sleep 0.5
              i=$((i + 1))
            done
          ''}/bin/nix-${suffix}"
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
  ];

  # NOTE: hostPlatform is set per-host from the darwinSystem `system` arg (via
  # the mkDarwin helper in flake.nix), NOT hardcoded here — so this shared module
  # serves both aarch64-darwin hosts (macos and macvm).

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
  # macOS System Settings ▸ Login Items is NOT declaratively manageable
  # (SMAppService / TCC-like). Nix-native: launchd user agents with RunAtLoad.
  #
  # BTM RULE: "Allow in the Background" names each item by ProgramArguments[0]
  # basename (`sfltool dumpbtm`). Always use a `nix-<activity>` wrapper
  # (mkNixAgent) — never bare /usr/bin/open, /bin/sh, or nix-darwin `script =`
  # (those wrap as /bin/sh -c wait4path and show as phantom "sh").
  # See docs/macos-settings-surface.md.
  #
  # Host scope: GUI login openers + Screengrab rotation are **macos only**.
  # macvm mounts the host's Screengrab via UTM VirtioFS (see hosts/macvm.nix +
  # macvm-utm-share-screengrab) — rotating it on the guest would trash host files
  # into the guest's ~/.Trash.
  launchd.user.agents = lib.mkIf (config.networking.hostName == "macos") {
    # Agent attr names (open-*) keep launchd Labels stable so existing BTM
    # toggle state is preserved. Turn OFF each app's own "Open at Login" so we
    # don't double-start (Docker AutoStart is also forced off at activation).
    open-maccy = mkNixAgent {
      suffix = "maccy";
      app = "Maccy";
    }; # menu-bar only (LSUIElement)
    open-docker = mkNixAgent {
      suffix = "docker";
      app = "Docker";
      processNames = [
        "Docker"
        "Docker Desktop"
      ];
      # Backend-first start; dashboard still may flash — re-hide covers it.
      extraOpenArgs = [ "--unattended" ];
    };
    open-slack = mkNixAgent {
      suffix = "slack";
      app = "Slack";
    };
    open-mail = mkNixAgent {
      suffix = "mail";
      app = "Mail";
    };
    open-messages = mkNixAgent {
      suffix = "messages";
      app = "Messages";
    };

    # Hourly rotation of ~/Pictures/Screengrab → ~/.Trash (recoverable).
    # Stock /bin + /usr/bin only (no Nix runtime). Direct ProgramArguments
    # with a nix-* basename — do NOT use `script =` (forces /bin/sh wrapper).
    # Path is atomic with system.defaults.screencapture.location above.
    file-rotation-screengrab = {
      serviceConfig = {
        Label = "${rdns}.file-rotation.trash-screengrab";
        ProgramArguments = [
          "${pkgs.writeShellScriptBin "nix-file-rotation-screengrab" ''
            set -eu
            /bin/mkdir -p "${home}/Library/Logs" "${home}/.Trash" "${screengrabDir}"
            /usr/bin/find "${screengrabDir}" -maxdepth 1 -type f ! -name '.DS_Store' -mmin +1440 \
              -exec /bin/sh -c 'for f do
                dest="${home}/.Trash/$(/usr/bin/basename "$f")"
                [ -e "$dest" ] && dest="$dest.$(/bin/date +%Y%m%d%H%M%S)"
                /bin/mv -- "$f" "$dest"
              done' _ {} +
          ''}/bin/nix-file-rotation-screengrab"
        ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/file-rotation-trash-screengrab.log";
        StandardErrorPath = "${home}/Library/Logs/file-rotation-trash-screengrab.log";
      };
    };
  };

  # Real Screengrab dir only on macos (owner of the files). macvm uses a symlink
  # to the UTM VirtioFS share (hosts/macvm.nix) — do not mkdir a local dir there.
  system.activationScripts.postActivation.text = lib.mkIf (config.networking.hostName == "macos") ''
        mkdir -p "${screengrabDir}"
        chown ${loginName} "${screengrabDir}"

        # Docker Desktop "Start when you log in" (settings-store AutoStart) races our
        # quiet open-docker agent and opens the dashboard. Keep AutoStart false so
        # only org.nixos.open-docker drives login start (menu-bar / no UI flash).
        docker_settings="${home}/Library/Group Containers/group.com.docker/settings-store.json"
        if [ -f "$docker_settings" ]; then
          /usr/bin/python3 - "$docker_settings" <<'PY' || true
    import json, sys
    path = sys.argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        sys.exit(0)
    if data.get("AutoStart") is False:
        sys.exit(0)
    data["AutoStart"] = False
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("docker: AutoStart forced off (open-docker owns login start)", file=sys.stderr)
    PY
          chown ${loginName}:staff "$docker_settings" 2>/dev/null || true
        fi
  '';

  # Window manager placeholder — uncomment and configure when adopted:
  # services.yabai.enable = true;
  # services.skhd.enable = true;

  # Touch ID for sudo — this fleet's sole Mac is Apple Silicon with a sensor.
  security.pam.services.sudo_local.touchIdAuth = true;
}
