# macOS desktop "look" — the custom wallpaper + Terminal.app profile (macOS only).
#
# These are the two cosmetic touches that make a darwin host recognisable AS this
# operator's Mac. They live behind `local.desktopAesthetics.enable` (default true)
# so a host can OPT OUT and fall back to the stock macOS look — used by `macvm`
# (hosts/macvm.nix) so the sandbox VM is visually distinct from the real `macos`
# machine (e.g. no custom wallpaper, no Ubuntu terminal — an at-a-glance tell,
# even before you read the hostname). Imported by modules/shared/home.nix; the
# assets (./wallpaper, ./terminal) are resolved relative to THIS file, i.e.
# modules/shared/, exactly as when they lived in home.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.desktopAesthetics;
in
{
  options.local.desktopAesthetics.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Apply this operator's custom macOS desktop look: the vendored desktop
      wallpaper and the Terminal.app "Ubuntu" profile. Default true (the real
      Mac). Set false on a host that should keep the stock macOS appearance so it
      is visually distinguishable (e.g. the macvm sandbox VM). No-op off macOS.
    '';
  };

  config = lib.mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    # ---- Terminal.app "Ubuntu" profile -------------------------------------
    # Installs ./terminal/Ubuntu.terminal — an Ubuntu-GNOME-look profile whose
    # colors + font mirror the VS Code integrated-terminal palette (home.nix).
    #
    # Terminal.app OWNS com.apple.Terminal and rewrites it from memory while it is
    # running, so a plain `defaults write` gets clobbered. The reliable path is to
    # let the running Terminal import the profile itself via `open`, which persists.
    # Guarded on absence so it runs ONCE (first activation on a fresh Mac) — later
    # rebuilds are a no-op and never pop a window. Setting it as the default is
    # best-effort (again, Terminal may overwrite while running): if it doesn't
    # stick, select Ubuntu → "Default" in Terminal ▸ Settings ▸ Profiles once.
    home.activation.ubuntuTerminalProfile = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! /usr/bin/defaults read com.apple.Terminal "Window Settings" 2>/dev/null \
           | /usr/bin/grep -q 'name = Ubuntu;'; then
        # `open` names the imported profile after the FILE basename. Opening the store
        # path directly imported it as "<hash>-Ubuntu", which this guard's `name = Ubuntu;`
        # never matched — so the step re-fired (popping a blank window) on EVERY activation,
        # and "Default/Startup Window Settings = Ubuntu" pointed at a profile that didn't
        # exist. Copy to a stable-named Ubuntu.terminal first so it imports as "Ubuntu".
        tmp="$(/usr/bin/mktemp -d)"
        $DRY_RUN_CMD /bin/cp ${./terminal/Ubuntu.terminal} "$tmp/Ubuntu.terminal"
        $DRY_RUN_CMD /usr/bin/open "$tmp/Ubuntu.terminal"
        $DRY_RUN_CMD /usr/bin/defaults write com.apple.Terminal \
          "Default Window Settings" -string "Ubuntu" || true
        $DRY_RUN_CMD /usr/bin/defaults write com.apple.Terminal \
          "Startup Window Settings" -string "Ubuntu" || true
      fi
    '';

    # ---- Terminal.app "Ubuntu" profile — post-import key reconcile ----------
    # The import above is deliberately ONCE-ONLY (guarded on the profile's absence),
    # so editing Ubuntu.terminal afterwards never reaches a Mac that already imported
    # it. Keys that must hold on an ALREADY-imported profile are reconciled here, in
    # place. Today that is exactly one: `shellExitAction` — Terminal ▸ Settings ▸
    # Profiles ▸ Shell ▸ "When the shell exits" — pinned to 1 = "Close if the shell
    # exited cleanly" (window closes on exit 0; a crash / non-zero exit keeps it open
    # so the error stays readable). 0 = always close, 2 = never close.
    #
    # It lives inside the nested `Window Settings` dict, so PlistBuddy — `defaults`
    # can only rewrite that dict wholesale. cfprefsd caches the domain and would
    # re-write the stale value over a direct file edit, hence the flush. Same caveat
    # as the import: Terminal.app owns com.apple.Terminal and rewrites it from memory
    # while running, so a patch applied with Terminal OPEN can be clobbered — it then
    # sticks on the next activation with Terminal closed. Guarded on the current
    # value, so it is a no-op once correct.
    home.activation.ubuntuTerminalShellExit = lib.hm.dag.entryAfter [ "ubuntuTerminalProfile" ] ''
      plist="$HOME/Library/Preferences/com.apple.Terminal.plist"
      key=':"Window Settings":Ubuntu:shellExitAction'
      if [ -f "$plist" ] && /usr/libexec/PlistBuddy -c 'Print :"Window Settings":Ubuntu' "$plist" >/dev/null 2>&1; then
        cur="$(/usr/libexec/PlistBuddy -c "Print $key" "$plist" 2>/dev/null || true)"
        if [ "$cur" != "1" ]; then
          $DRY_RUN_CMD /usr/libexec/PlistBuddy -c "Add $key integer 1" "$plist" >/dev/null 2>&1 || true
          $DRY_RUN_CMD /usr/libexec/PlistBuddy -c "Set $key 1" "$plist" >/dev/null 2>&1 || true
          $DRY_RUN_CMD /usr/bin/killall -u "$USER" cfprefsd >/dev/null 2>&1 || true
        fi
      fi
    '';

    # ---- Static desktop wallpaper ------------------------------------------
    # The vendored wallpaper.png (./wallpaper/wallpaper.png, version-controlled →
    # served from its immutable /nix/store copy). macOS keeps the desktop picture
    # in a sqlite db that `defaults` can't reliably read/write, so drive it via
    # System Events, which sets it for every display. Re-run each activation
    # (cheap, idempotent — it just re-points at the same store path).
    home.activation.setWallpaper = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD /usr/bin/osascript -e \
        'tell application "System Events" to tell every desktop to set picture to "${./wallpaper/wallpaper.png}"' || true
    '';
  };
}
