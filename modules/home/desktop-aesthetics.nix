# macOS desktop "look" — Terminal.app's type + colours (macOS only).
#
# Type on EVERY profile, and the four colours the OS actually exposes on `Pro`,
# which this block also forces as default/startup. UNGATED: every darwin host.
# Type size is ergonomics (the operator's eyes), so every darwin host gets it.
# Values come from `local.terminalTheme` (modules/home/terminal-theme.nix) — this
# module owns the DELIVERY, never the palette. This repo used to VENDOR a whole
# Terminal profile here ("Ubuntu", plus a generator script) and import it on first
# activation; #319 dropped that, and what replaces it is Apple's own scripting
# interface rather than an NSKeyedArchiver blob.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tt = config.lib.terminalTheme;
in
{
  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    # ---- Terminal.app — type everywhere, colours on `Pro` ---------------------
    # FOUR OF SIXTEEN SLOTS, and that is the OS ceiling, not a gap in this
    # module. Terminal's scripting dictionary exposes exactly four writable
    # colours on `settings set` — `cursor color` (sdef:368), `background
    # color` (:371), `normal text color` (:374), `bold text color` (:377) —
    # plus `font name` (:380) and `font size` (:383). There is NO ANSI ring:
    # `sdef Terminal.app | grep -ci ansi` returns 0. The ring lives only in
    # the NSKeyedArchiver blobs a vendored .terminal profile carries, which is
    # the approach #319 dropped.
    #
    # COLOURS GO TO `Pro` ONLY, unlike the size. `Pro` is the profile this
    # block already forces as default and startup, so it is the one actually
    # used; painting the aubergine ground onto every stock profile would
    # destroy Basic/Homebrew/Novel for no benefit. Type size stays UNGATED
    # across profiles — that is ergonomics, and its comment below still holds.
    #
    # BOLD TEXT = NORMAL TEXT, deliberately. Stock `Pro` makes bold brighter
    # than normal (#FFFFFF over ~#F2F2F2), but our foreground IS #FFFFFF, so
    # there is nothing brighter to move to. Using brightWhite (#EEEEEC) was
    # the obvious-looking alternative and is WRONG — it would render bold
    # DIMMER than normal text.
    #
    # This step writes UNVERSIONED user state: `home-manager rollback` does not
    # revert com.apple.Terminal. That was already true of the font size; it is
    # now true of five more properties.
    # Terminal has NO global font setting: type size lives per-profile, as an
    # NSKeyedArchiver'd NSFont blob (`Window Settings.<profile>.Font` →
    # `$objects[1].NSSize`). So "16pt no matter which profile is selected" means
    # touching every profile — hence the loop.
    #
    # Driven through Terminal's own AppleScript API, not a `defaults`/PlistBuddy
    # write — which rules out home-manager's `targets.darwin.defaults` and
    # `programs.macos-terminal` too, since both run `/usr/bin/defaults import` (home-manager/modules/targets/darwin/user-defaults/default.nix:21):
    # `font size` is a read/write integer on the `settings set` class (see
    # Terminal.sdef — only `id` is `access="r"`), and letting Terminal do the write is
    # the ONLY way it persists. Terminal owns com.apple.Terminal and rewrites it from
    # memory while running, so a direct plist edit gets clobbered.
    #
    # Guarded on Terminal ALREADY RUNNING, because `tell application "Terminal"` would
    # otherwise LAUNCH it and pop a window on every single rebuild — the exact
    # regression the old vendored-profile import had to be fixed for.
    #
    # DETECTION IS `pgrep`, NOT A `ps | grep -q` PIPE: home-manager's activate
    # script runs under `set -o pipefail`, and `grep -q` closing the pipe early
    # makes the pipeline report 141 on a SUCCESSFUL match. Measured; the full
    # story is docs/map/modules-home.md § desktop-aesthetics.nix.
    #
    # Re-run every activation, and cheap: EVERY property is compared before it is
    # written, so a settled Mac is a true no-op — and a profile ADDED later gets
    # its type bumped on the next rebuild. Both arms exit 0; activation never
    # fails over cosmetics (a missing `Pro` — only possible if hand-deleted —
    # just warns).
    home.activation.terminalAppearance = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if /usr/bin/pgrep -x Terminal >/dev/null; then
        run /usr/bin/osascript \
          -e 'tell application "Terminal"' \
          -e '  repeat with s in settings sets' \
          -e '    if font size of s is not ${toString tt.font.sizes.terminalApp} then set font size of s to ${toString tt.font.sizes.terminalApp}' \
          -e '  end repeat' \
          -e '  set default settings to settings set "Pro"' \
          -e '  set startup settings to settings set "Pro"' \
          -e '  tell settings set "Pro"' \
          -e '    if font name is not "${tt.font.postScriptName}" then set font name to "${tt.font.postScriptName}"' \
          -e '    if background color is not ${tt.toRgb16 tt.background} then set background color to ${tt.toRgb16 tt.background}' \
          -e '    if normal text color is not ${tt.toRgb16 tt.foreground} then set normal text color to ${tt.toRgb16 tt.foreground}' \
          -e '    if bold text color is not ${tt.toRgb16 tt.foreground} then set bold text color to ${tt.toRgb16 tt.foreground}' \
          -e '    if cursor color is not ${tt.toRgb16 tt.cursor} then set cursor color to ${tt.toRgb16 tt.cursor}' \
          -e '  end tell' \
          -e 'end tell' \
          || /usr/bin/printf '%s\n' "warning: Terminal.app type/colour step failed (osascript) — cosmetic, retried next activation"
      else
        /usr/bin/printf '%s\n' "warning: Terminal.app not running — skipped the type/colour step; it applies on the next activation from a Terminal"
      fi
    '';
  };
}
