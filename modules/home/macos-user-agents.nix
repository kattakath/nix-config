# home-manager module: the three macos-only user agents — Maccy's login opener
# and the two inbox Trash sweeps.
#
# WHY HOME MANAGER AND NOT nix-darwin's `launchd.user.agents` (moved 2026-10-02).
# Both layers place a user agent in ~/Library/LaunchAgents under gui/<uid>; only
# one REPAIRS it. The four surfaces and which mechanism covers which are
# enumerated once in modules/darwin/launchd-sources.nix, and these three sat on
# the one row covered by NEITHER (`selfHeals = false; domain = "gui"`):
#
#   • nix-darwin's activation is diff-gated in BOTH lanes — pinned nix-darwin
#     modules/system/launchd.nix wraps the system body at :19 and the user body
#     at :37 in `if ! diff <old> <new>` — so an UNCHANGED plist means the
#     unload/copy/load body never runs, and a unit macOS has dropped stays down.
#   • modules/darwin/launchd-reconcile.nix cannot reach it either: that script
#     runs as root from `postActivation` and from `activate-system`'s boot
#     script, where no user is logged in, so `gui/<uid>` does not exist.
#
# Home Manager PROBES instead of diffing: pinned home-manager
# modules/launchd/default.nix:445-452 takes the `cmp -s` "unchanged" branch and
# still asks `agentIsLoaded` (:326-330, a `launchctl print <domain>/<agentName>`),
# falling through to bootout + install + bootstrap on "up-to-date but not
# loaded". That probe keys off the LABEL, not the attribute name — `:165` names
# each plist `"${v.config.Label}.plist"` and `:426` derives
# `agentName="''${agentFile%.plist}"` straight back out of that filename — which
# is what makes the Label override below safe.
#
# THE LABELS ARE PINNED TO THEIR CURRENT ON-DISK VALUES, deliberately. Home
# Manager's default is `org.nix-community.home.<name>` (:114, a `lib.mkDefault`,
# and :254 documents the override), and taking that default would make each of
# these a DIFFERENT launchd unit: the operator's "Allow in the Background"
# approval in Background Task Management is keyed to the Label, so a rename
# silently drops the toggle and the unit reappears as a new, unapproved item.
# metube and yt-dlp-web-ui accepted that rename when they moved on 2026-09-22
# because neither is a BTM-approved background reader; these three are.
# `checks.<system>.launchd-selfheal-lane` gates both halves — the lane and the
# three Label strings.
#
# NOT `launchd.user.agents` IN A HOME-MANAGER MODULE EITHER: that option belongs
# to nix-darwin and does not exist here. `launchd.agents` is the whole surface
# this layer has, which is also why the move is a lane change and not a rename.
{
  config,
  lib,
  pkgs,
  domainName,
  # nix-darwin system config when this profile is embedded via
  # home-manager.darwinModules (absent on pure NixOS HM / standalone).
  osConfig ? { },
  ...
}:
let
  isMacosHost = (osConfig.networking.hostName or "") == "macos";
  home = config.home.homeDirectory;

  # Two SYSTEM-DEFAULT inboxes, two rotations (the agents below):
  #   folders.desktop   — ⇧⌘4/⇧⌘5 screenshots AND screen recordings (macOS's
  #                       own default target; the real Mac sets no location
  #                       override), swept WHOLE after 1 day.
  #   folders.downloads — browser downloads + AirDrop (every app's default;
  #                       nothing in this repo overrides it), swept after 7
  #                       days of DISPOSABLE types only (media/installers/
  #                       archives) — keepers move to Documents/Pictures/
  #                       Movies/Music by hand.
  # The paths themselves are the local.folders options
  # (modules/darwin/user-folders.nix): unset = the macOS system default,
  # override = the seam. Never re-derive "${home}/Downloads" inline — consume
  # the option. That option is declared by a nix-darwin SYSTEM module, so
  # `osConfig` is the only way to reach it from this layer (CLAUDE.md
  # § Configuration sanctions exactly that); a `or "${home}/Desktop"` fallback
  # here would BE the second copy the option exists to prevent. Nix let-bindings
  # are lazy and `lib.mkIf` never forces a dropped branch, so this is touched
  # only on `macos` — the Linux hosts and a standalone evaluation, where
  # `osConfig` has no `local`, never reach it.
  # Lineage: dedicated ~/Pictures/Screengrab → one all-in ~/Downloads inbox →
  # split back onto the system defaults behind mkOption (2026-09-05).
  folders = osConfig.local.folders;

  # Reverse-DNS namespace derived from the fleet domain (kattakath.com → com.kattakath)
  # for the file-rotation launchd labels, rather than hardcoding it.
  rdns = lib.concatStringsSep "." (lib.reverseList (lib.splitString "." domainName));

  # One byte-safe hourly Trash sweep, parameterized per inbox — every
  # deliberate choice in here is documented at the agents' definition site
  # below (TCC arg0, Put Back cost, tool survey, U+202F filenames).
  # `nameGlobs = null` sweeps EVERYTHING older than minAge (directories too);
  # a list of lowercase case(1) globs restricts the sweep to matching
  # basenames (case-insensitive via tr) and therefore SKIPS directories.
  #
  # NOT `nix-file-rotation-${suffix}`: modules/home/launchd-launcher.nix already
  # defaults `launcher.name = "nix-${name}"` for every agent, so the arg0 the
  # operator and TCC see is `nix-file-rotation-${suffix}` regardless. Naming the
  # inner script that too would produce `nix-file-rotation-desktop` exec'ing
  # `nix-file-rotation-desktop` — two store paths, one name (the trap
  # modules/home/metube.nix records as `metube-run`).
  mkTrashSweep =
    {
      suffix,
      dir,
      minAge, # minutes
      nameGlobs ? null,
    }:
    {
      # REQUIRED, and its absence is silent: `enable` is a `mkEnableOption`
      # defaulting to FALSE (pinned home-manager modules/launchd/default.nix:20),
      # and `agentPlists` filters on it (:166), so an agent declared without it
      # evaluates clean and renders NO plist at all. nix-darwin's
      # `launchd.user.agents` has no such switch, which is exactly how a
      # lane change loses a unit without a single eval error. Measured on this
      # migration: the first build of the three produced zero plists.
      enable = true;
      config = {
        Label = "${rdns}.file-rotation.trash-${suffix}";
        ProgramArguments = [
          "${pkgs.writeShellScriptBin "file-rotation-${suffix}-sweep" ''
            set -eu
            /bin/mkdir -p "${home}/Library/Logs" "${home}/.Trash"
            /usr/bin/find "${dir}" -mindepth 1 -maxdepth 1 \
              ! -name '.DS_Store' ! -name '.localized' -mmin +${toString minAge} \
              -exec /bin/sh -c 'for f do
                ${
                  lib.optionalString (nameGlobs != null) ''
                    base="$(/usr/bin/basename "$f" | /usr/bin/tr "[:upper:]" "[:lower:]")"
                    case "$base" in
                      ${lib.concatStringsSep "|" nameGlobs}) ;;
                      *) continue ;;
                    esac
                  ''
                }dest="${home}/.Trash/$(/usr/bin/basename "$f")"
                # -e also covers an existing DIRECTORY at $dest — without this,
                # `mv dir dest/` would move it INSIDE instead of renaming.
                if [ -e "$dest" ]; then
                  dest="$dest.$(/bin/date +%Y%m%d%H%M%S)"
                fi
                /bin/mv -- "$f" "$dest"
              done' _ {} +
          ''}/bin/file-rotation-${suffix}-sweep"
        ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "${home}/Library/Logs/file-rotation-trash-${suffix}.log";
        StandardErrorPath = "${home}/Library/Logs/file-rotation-trash-${suffix}.log";
      };
    };
in
{
  # ---- User agents (login opener + inbox rotations) ---------------------------
  # BTM RULE: "Allow in the Background" names each item by ProgramArguments[0]
  # basename (`sfltool dumpbtm`). Always use a `nix-<activity>` wrapper — never
  # bare /bin/sh or a `script =`/`waitForNixStore` wrapper (those render
  # ProgramArguments as /bin/sh -c wait4path and show as phantom "sh"). In this
  # lane modules/home/launchd-launcher.nix supplies that wrapper: it pins
  # `waitForNixStore = false` and `launcher.name = "nix-${name}"`, so arg0 is a
  # store-resident `nix-<attr>` script whichever way the Label is set.
  # The `nix-*` wrapper is also load-bearing for TCC *file access*, not just
  # cosmetics — see docs/macos-settings-surface.md § TCC and a /nix/store arg0.
  #
  # ONE launch-at-login opener survives: Maccy. Slack, Mail and Messages were
  # removed 2026-09-23 — each still raised a window at login despite `open -g
  # -j` plus a 12s System Events re-hide loop, and the operator wants a login
  # with no windows and no Dock churn. Maccy is LSUIElement (menu-bar only), so
  # it never was part of that complaint and it keeps its opener.
  #
  # Maccy had a DIFFERENT bug: a dead menu-bar icon that swallowed the first
  # click after login, needing a Spotlight relaunch. Cause: two launchers raced
  # — this agent AND a System Events login item. Measured 2026-09-23: deleting
  # that login item ALSO cleared Maccy's app-level BTM record, i.e. they were
  # one registration seen twice, not two. This agent is now the only launcher.
  # Do NOT re-add an `open-*` agent for a windowed app without a new decision.
  #
  # No hide loop here (unlike the retired Slack/Mail/Messages agents): Maccy has
  # no window to suppress, so `open -g -j` alone is the whole job.
  #
  # Host scope: all three are **macos only**, gated on `osConfig` because
  # `networking.hostName` is a nix-darwin value and this is a home-manager
  # module. (The historical reason the gate exists: the former macvm guest
  # symlinked its ~/Downloads to the host's over Tart VirtioFS, and a
  # guest-side rotation would have been destructive — mv(1) degrades to cp+rm
  # across filesystems, copying host bytes into the guest and unlinking them on
  # the host. The guest is gone (2026-09-05, docs/macvm-readd-runbook.md); keep
  # the gate anyway so a re-added guest can never inherit the sweeps by
  # accident.)
  launchd.agents = lib.mkIf isMacosHost {
    # Label pinned to the live `org.nixos.open-maccy` so existing BTM toggle
    # state survives the lane change — home-manager would otherwise name this
    # `org.nix-community.home.open-maccy`, a different unit. The attribute name
    # still supplies arg0 (`nix-open-maccy`) per
    # .claude/rules/launchd-naming.md — a bare /usr/bin/open would show in
    # "Allow in the Background" as a phantom "open". The inner script is NOT
    # called `nix-open-maccy` for the one-name-two-store-paths reason above.
    # `enable = true` is load-bearing — see the note in mkTrashSweep above.
    open-maccy = {
      enable = true;
      config = {
        Label = "org.nixos.open-maccy";
        ProgramArguments = [
          "${pkgs.writeShellScriptBin "open-maccy-run" ''
            set -eu
            exec /usr/bin/open -g -j -a Maccy
          ''}/bin/open-maccy-run"
        ];
        RunAtLoad = true;
      };
    };

    # The two inbox sweeps (mkTrashSweep above; hourly tick each; recoverable —
    # Finder erases Trash items at 30d via FXRemoveOldTrashItems). Stock
    # /bin + /usr/bin only (no Nix runtime).
    #
    # arg0 MUST stay a /nix/store `nix-*` wrapper — do NOT use `script =`,
    # /bin/sh, or `waitForNixStore = true`. Beyond BTM naming, that arg0 is what
    # grants these agents READ access to the TCC-protected ~/Desktop and
    # ~/Downloads at all (TCC attributes the read to the responsible binary; an
    # unattributable store path falls through to allow, /bin/sh gets EPERM). The
    # launcher keeps that property in this lane: it is itself a store script
    # with a store-resident interpreter (`launcher.shell = pkgs.runtimeShell`),
    # which is the trade upstream documents on that option and the reason
    # media-cli's TCC-reading queue agent works here. See
    # .claude/rules/launchd-naming.md § TCC.
    #
    # `-mindepth 1` is required or find would match the inbox dir itself.
    # `.localized` (Finder's localized-folder-name marker) and `.DS_Store` are
    # excluded: both are ancient by mtime and would be swept on the first run.
    #
    # The `-exec /bin/sh -c '…' _ {} +` shape is byte-safe and deliberate —
    # screenshot filenames contain U+202F (narrow no-break space), so any
    # "simplification" that matches on a literal shell space silently no-ops.
    #
    # ACCEPTED COST — Finder "Put Back" does not work on rotated items. A plain
    # `mv` into ~/.Trash writes no ptbL/ptbN records in .Trash/.DS_Store, so the
    # item can be dragged out but not restored to its origin. This is a
    # JUSTIFIED exception to the repo's reuse-over-rebuild preference —
    # off-the-shelf trash CLIs were surveyed and every one was disqualified:
    # trash-cli / rmtrash / gtrash / rmw target the freedesktop
    # ~/.local/share/Trash (the wrong trashcan on macOS); nixpkgs' darwin.trash
    # drives Apple Events, so it fails from a launchd context and its upstream is
    # 404; macos-trash is the only one that gets Put Back right and it is not in
    # nixpkgs. Do not "fix" this by swapping in one of those.

    # ~/Desktop: the capture inbox. Swept WHOLE (directories too) after 1 day —
    # the old Screengrab cadence. A directory's mtime tracks only entry
    # add/remove, so don't park live work on the Desktop.
    file-rotation-desktop = mkTrashSweep {
      suffix = "desktop";
      dir = folders.desktop;
      minAge = 1440;
    };

    # ~/Downloads: the browser/AirDrop inbox. Swept after 7 days, DISPOSABLE
    # types only — media, installers/disk images, archives. Everything else
    # (documents, folders — the typed filter never matches a directory) stays
    # put for manual triage into Documents/Pictures/Movies/Music; that is the
    # operator's explicit contract (2026-09-05), replacing the earlier
    # staged-30-day sweep-everything shape.
    file-rotation-downloads = mkTrashSweep {
      suffix = "downloads";
      dir = folders.downloads;
      minAge = 10080;
      nameGlobs = [
        # media
        "*.png"
        "*.jpg"
        "*.jpeg"
        "*.heic"
        "*.heif"
        "*.gif"
        "*.webp"
        "*.tiff"
        "*.tif"
        "*.bmp"
        "*.svg"
        "*.mp4"
        "*.mov"
        "*.m4v"
        "*.mkv"
        "*.webm"
        "*.avi"
        "*.mp3"
        "*.m4a"
        "*.aac"
        "*.wav"
        "*.flac"
        "*.aiff"
        "*.ogg"
        # installers / disk images
        "*.dmg"
        "*.pkg"
        "*.mpkg"
        "*.iso"
        "*.ipsw"
        "*.exe"
        "*.msi"
        "*.apk"
        # archives
        "*.zip"
        "*.tar"
        "*.gz"
        "*.tgz"
        "*.bz2"
        "*.tbz2"
        "*.xz"
        "*.txz"
        "*.zst"
        "*.7z"
        "*.rar"
      ];
    };
  };
}
