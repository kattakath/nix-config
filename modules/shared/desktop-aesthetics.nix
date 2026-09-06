# macOS desktop "look" — the Terminal.app type size + the custom wallpaper (macOS only).
#
# Two separate concerns, deliberately gated differently:
#
#   * Terminal.app — 16pt type on EVERY profile, stock `Pro` as the default/startup
#     profile. UNGATED: every darwin host. Type size is
#     ergonomics (the operator's eyes), not a visual tell, so the sandbox VM gets it
#     too. This repo used to VENDOR a whole Terminal profile here ("Ubuntu", plus a
#     generator script) and import it on first activation; that was dropped once stock
#     `Pro` turned out to be fine — the only thing worth holding declaratively is the
#     type size.
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
in
{
  options.local.desktopAesthetics.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Apply this operator's custom macOS desktop wallpaper. Default true (the real
      Mac). Set false on a host that should keep the stock macOS desktop so it is
      visually distinguishable (e.g. a sandbox VM). No-op off macOS. Does
      NOT cover the Terminal.app type size, which is applied on every darwin host.
    '';
  };

  config = lib.mkIf pkgs.stdenv.isDarwin (
    lib.mkMerge [
      # ---- Terminal.app — 16pt everywhere + stock `Pro` as the default ----------
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
      # regression the old vendored-profile import had to be fixed for. In practice the
      # operator rebuilds from a Terminal, so the guard passes; if it doesn't, the step
      # says so and applies on the next activation. Detection uses `ps`, NOT `pgrep`:
      # `pgrep -x Terminal` (and even `pgrep -f` on the full binary path) exits 1 from
      # the activation context while Terminal is demonstrably running.
      #
      # Re-run every activation, and cheap: the size is only written when it isn't
      # already 16, so a settled Mac is a true no-op — and a profile ADDED later gets
      # bumped on the next rebuild. Both arms exit 0; activation never fails over
      # cosmetics (a missing `Pro` — only possible if hand-deleted — just warns).
      {
        home.activation.terminalTypeSize = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          if /bin/ps -Ao comm | /usr/bin/grep -q '/Terminal.app/Contents/MacOS/Terminal$'; then
            $DRY_RUN_CMD /usr/bin/osascript \
              -e 'tell application "Terminal"' \
              -e '  repeat with s in settings sets' \
              -e '    if font size of s is not 16 then set font size of s to 16' \
              -e '  end repeat' \
              -e '  set default settings to settings set "Pro"' \
              -e '  set startup settings to settings set "Pro"' \
              -e 'end tell' \
              || /usr/bin/printf '%s\n' "warning: Terminal.app 16pt/Pro step failed (osascript) — cosmetic, retried next activation"
          else
            /usr/bin/printf '%s\n' "warning: Terminal.app not running — skipped the 16pt/Pro step; it applies on the next activation from a Terminal"
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
