# Spotlight-indexed .app bundles (macOS host only) — two kinds:
#
#   mkLauncherApp — "focus-or-launch" wrappers for GUI processes that have no
#                   .app of their own (the Android emulator, below).
#   mkCommandApp  — one bundle per FLEET OPERATION (activate, flake check,
#                   deploy nixpi, …), so Spotlight can run them by name.
#
# WHY .app BUNDLES AND NOT SPOTLIGHT'S "ACTIONS" LANE. macOS 26+ added a second
# Spotlight lane, Actions, and it is fed by exactly two things: App Intents (a
# Swift-only framework needing an Xcode app target and a signing identity) and
# Shortcuts.app. Neither is expressible here — Shortcuts live in an
# iCloud-synced sqlite store, and the `shortcuts` CLI (macOS 27, measured
# 2026-09-23) offers only run/list/view/sign, with NO import: creating one is a
# GUI act per Mac, which is the opposite of declarative. A Shortcuts "Run Shell
# Script" launched FROM Spotlight additionally fails "Operation not permitted"
# until Spotlight.app itself is hand-granted Full Disk Access, because the
# shortcut inherits the CALLING app's sandbox. The Applications lane has none of
# that: a bundle in ~/Applications is indexed on sight and survives a reset Mac
# with no clicks at all.
#
# The Android emulator (a bare qemu-system-aarch64 GUI process, see
# modules/shared/home.nix's `android-emu`) has no .app of its own, so
# Spotlight can't find it and re-launching spawns a duplicate instead of
# refocusing the existing window like a normal macOS app would.
#
# Each bundle here wraps a tiny launcher script: ask System Events whether a
# matching process is already running — if so, bring it frontmost; if not,
# launch it detached. Installed into ~/Applications via home.file (home.nix),
# which Spotlight indexes.
#
# Icons are ORIGINAL geometric glyphs rendered from hand-written SVG (not a
# reproduction of any vendor's trademarked artwork) — purely so Spotlight/the
# Dock show something more legible than the generic blank-app icon. Built
# entirely in-Nix (librsvg + libicns), no network fetch, no host fonts.
{
  lib,
  writeShellApplication,
  runCommand,
  librsvg,
  libicns,
}:
let
  # Simplified robot-head glyph on Android's brand green — evocative, not a
  # trace of the copyrighted "bugdroid" mascot artwork.
  androidIconSvg = ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
      <rect width="1024" height="1024" fill="#3DDC84"/>
      <line x1="430" y1="392" x2="398" y2="300" stroke="#FFFFFF" stroke-width="28" stroke-linecap="round"/>
      <line x1="594" y1="392" x2="626" y2="300" stroke="#FFFFFF" stroke-width="28" stroke-linecap="round"/>
      <circle cx="398" cy="300" r="22" fill="#FFFFFF"/>
      <circle cx="626" cy="300" r="22" fill="#FFFFFF"/>
      <path d="M 320 560 A 192 192 0 0 1 704 560 L 704 660 A 40 40 0 0 1 664 700 L 360 700 A 40 40 0 0 1 320 660 Z" fill="#FFFFFF"/>
      <circle cx="430" cy="565" r="30" fill="#3DDC84"/>
      <circle cx="594" cy="565" r="30" fill="#3DDC84"/>
    </svg>
  '';

  # Rasterize one SVG at the standard icns sizes, then pack them into a
  # single .icns — pure Nix (librsvg + libicns), no macOS-only `iconutil`
  # /.iconset naming convention required.
  #
  # Not nixpkgs' icon path either: that runs through desktopToDarwinBundle,
  # which converts an icon out of a share/icons THEME. There is no theme here —
  # each launcher carries one inline SVG defined in this file.
  mkIcns =
    name: svg:
    let
      svgFile = builtins.toFile "${name}.svg" svg;
      sizes = [
        16
        32
        64
        128
        256
        512
        1024
      ];
    in
    runCommand "${name}.icns"
      {
        nativeBuildInputs = [
          librsvg
          libicns
        ];
      }
      ''
        pngs=()
        for size in ${toString sizes}; do
          png="$TMPDIR/${name}-$size.png"
          rsvg-convert -w "$size" -h "$size" ${svgFile} -o "$png"
          pngs+=("$png")
        done
        png2icns "$out" "''${pngs[@]}"
      '';

  # ---- The command launchers' icon ---------------------------------------
  # The operator's own gold chevron mark. ./fleet-mark.svg is a VERBATIM copy of
  # ~/Pictures/icon.svg (`cmp`-clean), so refreshing it is a plain `cp` — which
  # is why the squaring below happens in Nix rather than in the committed file.
  #
  # Squaring is not cosmetic: the source canvas is 434.93933 x 448, and png2icns
  # needs exact NxN rasters. Rendering a non-square source into a square page
  # either letterboxes it or crops it (measured: `rsvg-convert --page-width 256
  # --page-height 256 -a` clipped the chevron's lower right). Rewriting the
  # viewBox to a centred 560 x 560 — the content box plus ~10% margin, so the
  # mark sits inside Apple's icon grid instead of touching the edges — makes a
  # plain `-w N -h N` exact.
  #
  # The nested-<svg> alternative was tried and does NOT work: librsvg renders
  # nothing for an `<image href="x.svg">` referencing an external SVG (measured
  # 2026-09-23 — a 352-byte, empty PNG), so the wrapper has to be a viewBox
  # rewrite on the source itself.
  fleetMarkCanvas = "width=\"434.93933\"\n   height=\"448\"\n   viewBox=\"0 2 434.93933 448\"";
  fleetMarkSquare = "width=\"560\"\n   height=\"560\"\n   viewBox=\"-62.53 -54 560 560\"";
  fleetMarkRaw = builtins.readFile ./fleet-mark.svg;
  fleetMarkSvg =
    # Fail at EVAL, loudly, if a refreshed mark no longer carries the canvas this
    # rewrite targets — the alternative is a silently letterboxed icon that only
    # shows up as "looks a bit off" in the Dock.
    assert lib.assertMsg (lib.hasInfix fleetMarkCanvas fleetMarkRaw) (
      "packages/fleet-mark.svg no longer declares the 434.93933x448 canvas that "
      + "packages/spotlight-launchers.nix squares. Re-measure its viewBox and "
      + "update fleetMarkCanvas/fleetMarkSquare before refreshing the file."
    );
    builtins.replaceStrings [ fleetMarkCanvas ] [ fleetMarkSquare ] fleetMarkRaw;

  # The window ground these bundles open on: the DARKEST stop of the mark's own
  # `goldDeep` gradient (grep stop-color in ./fleet-mark.svg), so the terminal
  # matches the icon that launched it.
  #
  # The darkest stop, not the pretty one, because a terminal ground has to carry
  # the theme's ink. Measured against `local.terminalTheme.foreground` (#FFFFFF,
  # modules/shared/terminal-theme.nix):
  #   #6b4300 -> 8.65:1   (this one; WCAG AA needs 4.5)
  #   #8a5a00 -> 5.93:1
  #   #a06a10 -> 4.60:1   — already marginal
  #   #b57b12 -> 3.62:1   — FAILS AA; the gold everyone reaches for first
  # Passed per-window on the Ghostty command line, so the fleet palette
  # (local.terminalTheme, #300A24 at 17.58:1) is untouched everywhere else.
  markGround = "#6b4300";

  # The same mark again, as a corner WATERMARK behind the text. Ghostty's
  # `background-image` takes "a path to a PNG or JPEG file, other image formats
  # are [unsupported]" (its own docs), so the SVG has to be rasterised into the
  # store — it cannot be handed the .svg directly.
  #
  # 256px at `fit = none`: `none` is the only fit that does NOT scale to the
  # window, which is what keeps this a corner mark instead of a full-bleed
  # backdrop (`contain`, the default, would stretch it to the full terminal
  # height). Opacity 0.35 so text stays first and the mark stays a watermark.
  fleetMarkPng =
    runCommand "fleet-mark.png"
      {
        nativeBuildInputs = [ librsvg ];
      }
      ''
        rsvg-convert -w 256 -h 256 ${builtins.toFile "fleet-mark-square.svg" fleetMarkSvg} -o "$out"
      '';

  # Every Ghostty window these bundles open wears the ground + the watermark.
  # One list, so the two shapes below cannot drift apart.
  ghosttyLook = [
    "--background=${markGround}"
    "--background-image=${fleetMarkPng}"
    "--background-image-position=bottom-right"
    "--background-image-fit=none"
    "--background-image-opacity=0.35"
  ];

  # Built ONCE and shared by every command bundle — same bytes, same store path,
  # three .app bundles pointing at one .icns.
  fleetMarkIcns = mkIcns "fleet-mark" fleetMarkSvg;

  # Assemble one .app bundle from a name, a bundle id, an .icns and a launcher
  # derivation exposing bin/launcher. Shared by both makers below.
  mkAppBundle =
    {
      name,
      slug,
      bundleId,
      icns,
      launcher,
    }:
    # grepped nixpkgs for a .app-bundle generator — `pkgs.writeDarwinBundle`
    # EXISTS (all-packages.nix:913) → custom anyway, because reading its
    # implementation rules it out on three counts
    # (build-support/make-darwin-bundle/write-darwin-bundle.nix):
    #   :13  CFBundleIdentifier is HARDCODED to "org.nixos.$name" with no
    #        parameter; this fleet needs com.kattakath.* identifiers.
    #   —    it emits no LSMinimumSystemVersion at all.
    #   :31  it requires the executable to already live at $prefix/bin/$execName,
    #        and it is reachable only through `desktopToDarwinBundle`, which
    #        wants a .desktop file plus a share/icons theme to convert — neither
    #        exists here (these bundles are Nix-defined, with one inline SVG).
    # Repo-wide grep for writeDarwinBundle: zero other hits.
    runCommand "${slug}-app" { } ''
      mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
      cat > "$out/Contents/Info.plist" <<PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>CFBundleName</key><string>${name}</string>
        <key>CFBundleDisplayName</key><string>${name}</string>
        <key>CFBundleIdentifier</key><string>${bundleId}</string>
        <key>CFBundleExecutable</key><string>launcher</string>
        <key>CFBundleIconFile</key><string>icon</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CFBundleShortVersionString</key><string>1.0</string>
        <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
        <key>LSMinimumSystemVersion</key><string>11.0</string>
      </dict>
      </plist>
      PLIST
      cp ${launcher}/bin/launcher "$out/Contents/MacOS/launcher"
      chmod +x "$out/Contents/MacOS/launcher"
      cp ${icns} "$out/Contents/Resources/icon.icns"
    '';

  mkLauncherApp =
    {
      # Display name (CFBundleName) — also the ~/Applications/<name>.app filename.
      name,
      # Reverse-DNS bundle id.
      bundleId,
      # Substring (AppleScript `contains` is case-insensitive) matched against
      # System Events' application-process names to detect "already running".
      processMatch,
      # Command to run (resolved via the PATH set below) when nothing matches.
      launchCommand,
      # SVG source for the app icon (see mkIcns above).
      iconSvg,
    }:
    let
      slug = lib.replaceStrings [ " " ] [ "-" ] (lib.toLower name);
      icns = mkIcns slug iconSvg;
      launcher = writeShellApplication {
        name = "launcher";
        text = ''
          # Spotlight/LaunchServices launches this with a minimal PATH — put the
          # per-user Nix profile + Homebrew ahead of the base system dirs. $(id -un)
          # keeps this free of a hardcoded username (identical trick used nowhere
          # else needs to hardcode /Users/<name>; this is a runtime lookup).
          PATH="/etc/profiles/per-user/$(id -un)/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          export PATH

          # `|| true` + the fallback assign: a denied/not-yet-granted Automation
          # permission makes osascript exit non-zero, and `set -e` (from
          # writeShellApplication) would otherwise abort here — before ever
          # launching anything on a first run, exactly when it's needed most.
          result=$(/usr/bin/osascript <<'APPLESCRIPT' || true
          tell application "System Events"
            set matches to every application process whose name contains "${processMatch}"
            if (count of matches) > 0 then
              set frontmost of item 1 of matches to true
              return "activated"
            else
              return "not-running"
            end if
          end tell
          APPLESCRIPT
          )
          result="''${result:-not-running}"

          if [ "$result" != "activated" ]; then
            log_dir="$HOME/Library/Logs"
            mkdir -p "$log_dir"
            nohup ${launchCommand} >"$log_dir/${name}-launch.log" 2>&1 &
            disown
          fi
        '';
      };
    in
    mkAppBundle {
      inherit
        name
        slug
        bundleId
        icns
        launcher
        ;
    };
  # ---- One .app per fleet operation --------------------------------------
  # `terminal = true` (the default) opens a NEW GHOSTTY WINDOW running the
  # command, because none of these are fire-and-forget: `activate` raises a
  # Touch ID sheet (packages/activate.nix re-execs under sudo, which needs a
  # visible session) and every nix command here prints a build log worth
  # reading. Ghostty's OWN `--wait-after-command` holds the window open after
  # the command exits — upstream's option, not a hand-rolled trailing `read`
  # (.claude/rules/upstream-first.md). `terminal = false` is for the two whose
  # target has its own window (the editor, the browser).
  #
  # `open -na Ghostty.app --args … -e CMD ARGS…` is the ONLY supported way in:
  # `ghostty --help` says launching the emulator from the CLI is unsupported on
  # macOS and to use `open -na Ghostty.app`. Measured 2026-09-23 on Ghostty
  # 1.3.1: a second `open -n` while Ghostty is already running opens a new
  # WINDOW inside the EXISTING process (pgrep -x ghostty stays at 1), so the new
  # window does NOT inherit this launcher's environment — it inherits the first
  # window's. That is why the flake directory travels as an ARGV element ("$1"
  # to the inner `zsh -lc`) and never as an exported variable, which would
  # silently resolve to whatever the first Ghostty launch happened to see.
  #
  # The inner shell is a LOGIN zsh on purpose: /etc/zshenv sources nix-darwin's
  # set-environment, so nix, darwin-rebuild and the per-user profile are on PATH
  # regardless of what launchd handed the .app.
  mkCommandApp =
    {
      # Display name (CFBundleName) — also the ~/Applications/<name>.app
      # filename and what Spotlight matches. Every one starts "Nix " so a single
      # `nix` query surfaces the whole set.
      name,
      # Reverse-DNS bundle id.
      bundleId,
      # Shell text. The nix-config working tree is "$1" when usesFlakeDir.
      # Unused — and must be omitted — when shape = "shell".
      command ? null,
      # How the bundle runs:
      #   "terminal" — a new Ghostty window running `command` (the default)
      #   "shell"    — a new Ghostty window sitting in the working tree, no
      #                command: an ordinary interactive prompt in the repo
      #   "quiet"    — `command` straight from the launcher, no window of ours
      shape ? "terminal",
      # Resolve the working tree and pass it as "$1". Off for the operations
      # that never touch the repo (rollback, the doctors, the web search).
      usesFlakeDir ? true,
    }:
    assert lib.assertOneOf "shape" shape [
      "terminal"
      "shell"
      "quiet"
    ];
    assert lib.assertMsg (
      (shape == "shell") == (command == null)
    ) "mkCommandApp: shape = \"shell\" takes no command, every other shape requires one.";
    let
      slug = lib.replaceStrings [ " " ] [ "-" ] (lib.toLower name);
      # Every command bundle wears the same mark, so this is ONE shared .icns.
      icns = fleetMarkIcns;
      launcher = writeShellApplication {
        name = "launcher";
        text = ''
          # LaunchServices starts this with a minimal PATH. $(id -un) keeps it
          # free of a hardcoded /Users/<name>; /run/current-system/sw/bin is
          # where darwin-rebuild lives, /opt/homebrew/bin where `code` does.
          PATH="/etc/profiles/per-user/$(id -un)/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          export PATH

          ${lib.optionalString usesFlakeDir ''
            # The working tree, resolved EXACTLY the way darwin-rebuild resolves
            # it: nix-darwin plants /etc/nix-darwin/flake.nix as a symlink INTO
            # the live clone (modules/parts/hosts.nix), so no repo path is baked
            # in here and a moved clone repoints launcher and rebuild together.
            flake_dir=$(dirname "$(readlink -f /etc/nix-darwin/flake.nix 2>/dev/null || true)")
            if [ ! -d "$flake_dir" ]; then
              # A GUI launch has nowhere to print — say it in an alert instead of
              # dying silently, which is the one failure mode Spotlight hides.
              /usr/bin/osascript -e 'display alert "nix-config not found" message "/etc/nix-darwin/flake.nix does not resolve to a directory. Re-activate once with --flake to repair the link."' >/dev/null 2>&1 || true
              exit 1
            fi
          ''}
          ${
            {
              # `--wait-after-command` holds the window open on the command's
              # exit — Ghostty's own option, not a hand-rolled trailing `read`.
              terminal = ''
                # SC2016 is the POINT here, not a slip: the command must reach
                # the inner `zsh -lc` UNEXPANDED so its own "$1" resolves there.
                # shellcheck disable=SC2016
                exec /usr/bin/open -na Ghostty.app --args \
                  --title=${lib.escapeShellArg name} ${lib.concatStringsSep " " ghosttyLook} \
                  --wait-after-command=true \
                  -e /bin/zsh -lc ${lib.escapeShellArg command} ${slug}${lib.optionalString usesFlakeDir " \"$flake_dir\""}
              '';
              # No `-e`: Ghostty's own `--working-directory` opens an ORDINARY
              # interactive window already sitting in the tree, with its shell
              # integration intact — which `-e zsh -lc 'cd … && exec zsh'` would
              # not have (upstream-first: pinned Ghostty 1.3.1 config key,
              # `ghostty +show-config --default` line 350).
              shell = ''
                exec /usr/bin/open -na Ghostty.app --args \
                  --title=${lib.escapeShellArg name} ${lib.concatStringsSep " " ghosttyLook} \
                  --working-directory="$flake_dir"
              '';
              quiet = ''
                ${lib.optionalString usesFlakeDir ''set -- "$flake_dir"''}
                ${command}
              '';
            }
            .${shape}
          }
        '';
      };
    in
    mkAppBundle {
      inherit
        name
        slug
        bundleId
        icns
        launcher
        ;
    };

in
{
  androidEmulatorApp = mkLauncherApp {
    name = "Android Emulator";
    bundleId = "com.kattakath.android-emulator";
    processMatch = "qemu-system";
    launchCommand = "android-emu";
    iconSvg = androidIconSvg;
  };
  # (The "Mac VM" launcher left with the macvm host, 2026-09-05.)

  # THREE fleet operations, each a Spotlight-findable bundle. Every name starts
  # "Nix " so one `nix` query lists the set, and every one wears the same gold
  # mark — they are told apart by NAME in the results row, not by icon.
  #
  # Deliberately small, and it got smaller twice on 2026-09-23 — both times
  # because a one-click button for something that does not work is worse than no
  # button. Recording what came out, so none of it gets re-proposed as an
  # oversight:
  #   · the nixpi deploy — `deploy --targets .#nixpi` still failed for the
  #     operator AFTER a successful Cloudflare Access login. The deploy lines in
  #     CLAUDE.md § Build & Commands stay the supported path.
  #   · "Nix Launchd Doctor" — `launchd-doctor` is NOT on a login shell's PATH,
  #     so the bundle opened a window only to print `command not found`.
  #   · update-inputs / rollback / determinate-status / search-packages —
  #     dropped as unused, not as broken.
  #   · garbage collection, which was never added: macos already runs
  #     Determinate's automatic collector (modules/parts/compose.nix:
  #     determinateNixd.garbageCollector.strategy = "automatic"), so a manual
  #     `nix-collect-garbage -d` button would fight the thing that owns the store.
  #   · anything that INSTALLS or REMOVES a package. This fleet is declarative:
  #     installing is an edit to hosts/macos.nix followed by `activate`, so the
  #     honest Spotlight action is "Nix Open Repo", not `nix profile install`.
  commandApps = {
    # The everyday one. `activate` self-elevates, so this raises the Touch ID
    # sheet in the new Ghostty window rather than dying on a sudo with no tty.
    "Nix Activate" = mkCommandApp {
      name = "Nix Activate";
      bundleId = "com.kattakath.nix-activate";
      command = "activate";
      usesFlakeDir = false;
    };

    # `git add -A` first because flakes IGNORE untracked files
    # (.claude/rules/git-purity.md) — without it a new .nix is invisible and the
    # check passes on a tree that does not exist.
    "Nix Flake Check" = mkCommandApp {
      name = "Nix Flake Check";
      bundleId = "com.kattakath.nix-flake-check";
      command = ''cd "$1" && git add -A && nix flake check --all-systems --no-build'';
    };

    # A terminal already sitting in the tree — the declarative answer to
    # "install something". It replaced a `code "$1"` bundle on 2026-09-23: the
    # editor opened but NOT on the repo, and Ghostty is where the other two
    # already land, so one window type serves the whole row.
    "Nix Open Repo" = mkCommandApp {
      name = "Nix Open Repo";
      bundleId = "com.kattakath.nix-open-repo";
      shape = "shell";
    };
  };
}
