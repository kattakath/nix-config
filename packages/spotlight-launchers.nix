# "Focus-or-launch" Spotlight app bundles (macOS host only).
#
# The Android emulator (a bare qemu-system-aarch64 GUI process, see
# modules/shared/home.nix's `android-emu`) and macvm (a Tart-run window, see
# packages/macvm-tart.nix's `macvm-tart-start`) have no .app of their own, so
# Spotlight can't find them and re-launching either one spawns a duplicate
# instead of refocusing the existing window like a normal macOS app would.
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

  # Nested-screen ("window inside a window") glyph on macOS system blue —
  # a monitor + stand with a smaller inset display standing in for
  # virtualization (a computer running inside a computer).
  macvmIconSvg = ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
      <rect width="1024" height="1024" fill="#0A84FF"/>
      <rect x="180" y="260" width="664" height="430" rx="44" fill="#FFFFFF"/>
      <rect x="472" y="690" width="80" height="70" fill="#FFFFFF"/>
      <rect x="382" y="748" width="260" height="34" rx="17" fill="#FFFFFF"/>
      <rect x="336" y="378" width="352" height="222" rx="26" fill="#0A84FF"/>
      <rect x="392" y="418" width="240" height="142" rx="16" fill="#FFFFFF"/>
    </svg>
  '';

  # Rasterize one SVG at the standard icns sizes, then pack them into a
  # single .icns — pure Nix (librsvg + libicns), no macOS-only `iconutil`
  # /.iconset naming convention required.
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
          result=$(/usr/bin/osascript <<APPLESCRIPT || true
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
in
{
  androidEmulatorApp = mkLauncherApp {
    name = "Android Emulator";
    bundleId = "com.kattakath.android-emulator";
    processMatch = "qemu-system";
    launchCommand = "android-emu";
    iconSvg = androidIconSvg;
  };

  macvmApp = mkLauncherApp {
    name = "Mac VM";
    bundleId = "com.kattakath.macvm-tart";
    processMatch = "tart";
    launchCommand = "macvm-tart-start";
    iconSvg = macvmIconSvg;
  };
}
