# macOS desktop "look" — Terminal.app's type + colours, and the custom wallpaper
# (macOS only).
#
# Two separate concerns, deliberately gated differently:
#
#   * Terminal.app — type on EVERY profile, and the four colours the OS actually
#     exposes on `Pro`, which this block also forces as default/startup. UNGATED:
#     every darwin host. Type size is ergonomics (the operator's eyes), not a
#     visual tell, so the sandbox VM gets it too. Values come from
#     `local.terminalTheme` (modules/shared/terminal-theme.nix) — this module owns
#     the DELIVERY, never the palette. This repo used to VENDOR a whole Terminal
#     profile here ("Ubuntu", plus a generator script) and import it on first
#     activation; #319 dropped that, and what replaces it is Apple's own scripting
#     interface rather than an NSKeyedArchiver blob.
#   * The wallpaper — behind `local.desktopAesthetics.enable` (default true), so a host
#     can OPT OUT and keep the stock macOS desktop (the former macvm guest did
#     exactly that, keeping the sandbox visually distinct from the real `macos`
#     machine at a glance, before you read the hostname.
#
# Imported by modules/shared/home.nix; ./wallpaper is resolved relative to THIS file,
# i.e. modules/shared/, exactly as when it lived in home.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.desktopAesthetics;
  tt = config.lib.terminalTheme;
in
{
  options.local.desktopAesthetics.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Apply this operator's custom macOS desktop wallpaper. Default true (the real
      Mac). Set false on a host that should keep the stock macOS desktop so it is
      visually distinguishable (e.g. a sandbox VM). No-op off macOS. Does
      NOT cover the Terminal.app type or colours, which apply on every darwin host.
    '';
  };

  config = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin (
    lib.mkMerge [
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
      # write: `font size` is a read/write integer on the `settings set` class (see
      # Terminal.sdef — only `id` is `access="r"`), and letting Terminal do the write is
      # the ONLY way it persists. Terminal owns com.apple.Terminal and rewrites it from
      # memory while running, so a direct plist edit gets clobbered.
      #
      # Guarded on Terminal ALREADY RUNNING, because `tell application "Terminal"` would
      # otherwise LAUNCH it and pop a window on every single rebuild — the exact
      # regression the old vendored-profile import had to be fixed for.
      #
      # DETECTION IS `pgrep`, AND IT MUST NOT BE A PIPE. This comment used to claim the
      # opposite — "use `ps`, NOT `pgrep`, because pgrep exits 1 from the activation
      # context while Terminal is demonstrably running" — and that was a MISDIAGNOSIS of
      # the bug below. `pgrep` was never the problem; the pipe was.
      #
      # home-manager's generated activate script runs under `set -o pipefail` (its line
      # 3). `grep -q` exits the instant it matches, which closes the pipe, which kills
      # `ps` with SIGPIPE — so the PIPELINE reports 141 even though the match SUCCEEDED,
      # and `pipefail` hands that 141 to the `if`. The step then skipped forever, on a
      # machine where Terminal was running the whole time. Measured in the exact
      # activation context (`launchctl asuser <uid> sudo -u <user>`, per nix-darwin's
      # own activate script):
      #
      #   set -o pipefail; ps -Ao comm | grep -q '…/Terminal$'   -> exit 141   FAIL
      #   set -o pipefail; pgrep -x Terminal >/dev/null          -> exit 0     PASS
      #
      # So: no pipe in a guard that runs under `pipefail`, and never `cmd | grep -q` when
      # the producer is long enough to still be writing. `pgrep` needs neither.
      #
      # Re-run every activation, and cheap: EVERY property is compared before it is
      # written, so a settled Mac is a true no-op — and a profile ADDED later gets
      # its type bumped on the next rebuild. Both arms exit 0; activation never
      # fails over cosmetics (a missing `Pro` — only possible if hand-deleted —
      # just warns).
      {
        home.activation.terminalAppearance = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if /usr/bin/pgrep -x Terminal >/dev/null; then
            $DRY_RUN_CMD /usr/bin/osascript \
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
      }

      # ---- Static desktop wallpaper --------------------------------------------
      # The vendored wallpaper.png (./wallpaper/wallpaper.png, version-controlled →
      # served from its immutable /nix/store copy).
      #
      # upstream option home-manager.programs.desktoppr exists → using it
      # (modules/programs/desktoppr.nix:16 enable, :26 settings.picture typed
      # `nullOr (either path url)`, :94 a darwin platform assertion, :98
      # targets.darwin.defaults.desktoppr, :100 an activation entryAfter
      # "setDarwinDefaults" running `desktoppr manage`). It wraps
      # scriptingosx/desktoppr, which talks to NSWorkspace directly.
      #
      # This replaced a hand-rolled `home.activation.setWallpaper` osascript
      # one-liner driving System Events. The old comment correctly ruled out
      # `defaults` — macOS keeps the desktop picture in a sqlite db — but never
      # considered a purpose-built CLI, which is exactly the gap
      # .claude/rules/upstream-first.md exists to catch.
      #
      # TRADE: pkgs.desktoppr (0.5) is a swift/swiftpm build with
      # `versionCheckHook`, so the FIRST activation compiles it unless Cachix has
      # it warm. In exchange the System Events Automation TCC dependency goes
      # away — worth it, and a different (smaller) consent prompt on a fresh Mac.
      #
      # WHY THE home.file INDIRECTION rather than `settings.picture = ./…png`:
      # upstream routes the value through `targets.darwin.defaults`, which builds
      # the plist with `builtins.derivation` and LOSES the string context — Nix
      # says so out loud ("references the store path … without a proper context").
      # Measured both ways on the darwin-system drv with `nix-store -qR | grep -i
      # wallpaper`: with `settings.picture` set to the path directly the closure
      # contains NO wallpaper entry at all, so `nix-collect-garbage` would delete
      # it and the desktop would silently revert; with the home.file indirection
      # the closure contains `…-hm_wallpaper.png`. The old osascript
      # activation did not have this problem — an activation script IS part of the
      # generation, so the path stayed rooted. Pointing desktoppr at a home.file
      # symlink restores that: home.file keeps the store path in the generation's
      # closure, and desktoppr reads through the link.
      (lib.mkIf cfg.enable {
        home.file.".local/share/nix-desktop-wallpaper.png".source = ./wallpaper/wallpaper.png;

        programs.desktoppr = {
          enable = true;
          settings.picture = "${config.home.homeDirectory}/.local/share/nix-desktop-wallpaper.png";
        };
      })
    ]
  );
}
