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
  # THE single staging folder: browser downloads, AirDrop, ⇧⌘5 screenshots AND
  # screen recordings all land here, and the launchd agent below rotates it
  # hourly into ~/.Trash. Replaced the old ~/Pictures/Screengrab dir — one
  # inbox, one rotation, and Downloads is where every app already defaults.
  downloadsDir = "${home}/Downloads";
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
    # macos: accept Xcode license (and pre-install Xcode.app) before brew bundle.
    ./xcode-license.nix
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

      # Save screen captures into the rotated Downloads dir (not ~/Desktop).
      # This one key covers BOTH ⇧⌘4 screenshots and ⇧⌘5 screen *recordings* —
      # verified empirically; the .mov honors com.apple.screencapture location
      # despite Apple documenting no separate key for recordings.
      screencapture = {
        location = downloadsDir;
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

  # ---- Launch-at-login agents (declarative "Open at Login") ------------------
  # macOS System Settings ▸ Login Items is NOT declaratively manageable
  # (SMAppService / TCC-like). Nix-native: launchd user agents with RunAtLoad.
  #
  # BTM RULE: "Allow in the Background" names each item by ProgramArguments[0]
  # basename (`sfltool dumpbtm`). Always use a `nix-<activity>` wrapper
  # (mkNixAgent) — never bare /usr/bin/open, /bin/sh, or nix-darwin `script =`
  # (those wrap as /bin/sh -c wait4path and show as phantom "sh").
  # The `nix-*` wrapper is also load-bearing for TCC *file access*, not just
  # cosmetics — see docs/macos-settings-surface.md § TCC and a /nix/store arg0.
  #
  # Host scope: GUI login openers + Downloads rotation are **macos only**.
  # macvm symlinks its ~/Downloads to the host's over Tart VirtioFS (see
  # hosts/macvm.nix + macvm-tart-start). A guest rotation would be destructive,
  # not merely redundant: mv(1) states "As the rename(2) call does not work
  # across file systems, mv uses cp(1) and rm(1)" — so trashing across the
  # VirtioFS boundary would COPY host bytes into the guest's disk image and
  # then UNLINK them on the host. Never relax this gate.
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

    # Hourly rotation of ~/Downloads → ~/.Trash (recoverable; Finder then erases
    # Trash items at 30d via FXRemoveOldTrashItems above). Stock /bin + /usr/bin
    # only (no Nix runtime).
    #
    # arg0 MUST stay a /nix/store `nix-*` wrapper — do NOT use `script =` or
    # /bin/sh. Beyond BTM naming, that arg0 is what grants this agent READ
    # access to ~/Downloads at all (TCC attributes the read to the responsible
    # binary; an unattributable store path falls through to allow, /bin/sh gets
    # EPERM). See .claude/rules/launchd-naming.md § TCC.
    #
    # Retention: 43200 min = 30 days. This is a deliberately STAGED value —
    # ~/Downloads already holds a large untriaged backlog and a 7-day first run
    # would sweep all of it into the Trash at once. The intended steady state is
    # 7 days (`-mmin +10080`); once the backlog is triaged this is a one-number
    # edit, nothing else changes.
    #
    # Directories rotate too (no `-type f`), so unzipped folders don't accumulate
    # forever. Two consequences that are intentional: `-mindepth 1` is now
    # required or find would match ~/Downloads itself, and a directory's mtime
    # tracks only entry add/remove — editing a file deep inside does not renew
    # its parent, so a long-lived project folder can age out. Keep real work out
    # of ~/Downloads.
    #
    # `.localized` (Finder's localized-folder-name marker) and `.DS_Store` are
    # excluded: both are ancient by mtime and would be swept on the first run.
    #
    # The `-exec /bin/sh -c '…' _ {} +` shape is byte-safe and deliberate —
    # screenshot filenames contain U+202F (narrow no-break space), so any
    # "simplification" that matches on a literal shell space silently no-ops.
    #
    # ACCEPTED COST — Finder "Put Back" does not work on rotated items. A plain
    # `mv` into ~/.Trash writes no ptbL/ptbN records in .Trash/.DS_Store, so the
    # item can be dragged out but not restored to its origin. Already true of the
    # old Screengrab rotation; it just matters more now that real downloads move.
    # This is a JUSTIFIED exception to the repo's reuse-over-rebuild preference —
    # off-the-shelf trash CLIs were surveyed and every one was disqualified:
    # trash-cli / rmtrash / gtrash / rmw target the freedesktop
    # ~/.local/share/Trash (the wrong trashcan on macOS); nixpkgs' darwin.trash
    # drives Apple Events, so it fails from a launchd context and its upstream is
    # 404; macos-trash is the only one that gets Put Back right and it is not in
    # nixpkgs. Do not "fix" this by swapping in one of those.
    file-rotation-downloads = {
      serviceConfig = {
        Label = "${rdns}.file-rotation.trash-downloads";
        ProgramArguments = [
          "${pkgs.writeShellScriptBin "nix-file-rotation-downloads" ''
            set -eu
            /bin/mkdir -p "${home}/Library/Logs" "${home}/.Trash"
            /usr/bin/find "${downloadsDir}" -mindepth 1 -maxdepth 1 \
              ! -name '.DS_Store' ! -name '.localized' -mmin +43200 \
              -exec /bin/sh -c 'for f do
                dest="${home}/.Trash/$(/usr/bin/basename "$f")"
                # -e also covers an existing DIRECTORY at $dest — without this,
                # `mv dir dest/` would move it INSIDE instead of renaming.
                if [ -e "$dest" ]; then
                  dest="$dest.$(/bin/date +%Y%m%d%H%M%S)"
                fi
                /bin/mv -- "$f" "$dest"
              done' _ {} +
          ''}/bin/nix-file-rotation-downloads"
        ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/file-rotation-trash-downloads.log";
        StandardErrorPath = "${home}/Library/Logs/file-rotation-trash-downloads.log";
      };
    };
  };

  # macos only: macvm's ~/Downloads is a symlink to the Tart VirtioFS share
  # (hosts/macvm.nix) — never mkdir/chown a local dir over it there.
  #
  # `mkdir -p` is belt-and-braces for nix-darwin#1240: a screencapture.location
  # that does not exist is silently ignored and captures fall back to ~/Desktop.
  # ~/Downloads always exists on a real macOS account, so this is a no-op.
  # Deliberately NO `chown`: unlike the old dedicated Screengrab dir, ~/Downloads
  # is a large pre-existing user folder that is already correctly owned — a
  # recursive-adjacent ownership change there is risk with no upside.
  system.activationScripts.postActivation.text = lib.mkIf (config.networking.hostName == "macos") ''
        mkdir -p "${downloadsDir}"

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

        # Propagate the GUI PATH (see § GUI PATH above) to Dock-launched apps.
        # macOS gives a launched app the LAUNCHING process's environment, so an
        # app opened from the Dock inherits Dock's snapshot — not the current
        # launchd value. nix-darwin restarts Dock in activationScripts.defaults,
        # which runs BEFORE activationScripts.userLaunchd emits `launchctl
        # setenv` (see the generated activate script: Dock restart ~line 1377,
        # setenv ~line 1481), so Dock always holds the PREVIOUS environment and
        # every Dock-launched app misses the fix. postActivation is the last
        # hook, hence the only place this can be corrected. Upstream models no
        # ordering control and no GUI-env refresh — grepped nix-darwin/modules
        # for `killall Dock`/`killall cfprefsd`: zero hits.
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
