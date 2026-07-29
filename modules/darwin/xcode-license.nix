# Accept the Xcode license (and ensure Xcode.app is present) BEFORE Homebrew's
# `brew bundle` during nix-darwin activation.
#
# Why this exists
# ---------------
# nix-darwin's generated Brewfile installs in this order: taps → brews → casks →
# masApps. Formulae that need a C compiler / SDKs therefore run *before* the
# `mas "Xcode"` entry, and fail hard with:
#
#   Error: You have not agreed to the Xcode license. Please resolve this by
#   running: sudo xcodebuild -license accept
#
# even when Xcode is about to be installed later in the same brew bundle (or is
# already on disk from a prior MAS install but still unlicensed after a wipe).
#
# Fix
# ---
# Inject into `system.activationScripts.homebrew` via `lib.mkBefore` so this
# runs as root *immediately before* the brew-bundle body (activation order is
# fixed in nix-darwin: … → mas → homebrew → postActivation). When
# `homebrew.masApps.Xcode` is set, also proactively `mas install` that app as
# the Homebrew user so a clean bootstrap has Xcode.app before any formulae.
#
# Scoped to `networking.hostName == "macos"` — macvm has no Xcode / no MAS.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.homebrew;
  # Present only when the host declares Xcode in masApps (hosts/macos.nix).
  xcodeMasId = cfg.masApps.Xcode or null;
  enabled = cfg.enable && config.networking.hostName == "macos";
  brewUser = cfg.user;
  brewPrefix = cfg.prefix;
  masBin = lib.getExe pkgs.mas;
in
{
  config = lib.mkIf enabled {
    system.activationScripts.homebrew.text = lib.mkBefore ''
      # ---- Xcode presence + license (must precede brew bundle) ----------------
      echo >&2 "Xcode: ensuring app + license before Homebrew bundle..."

      ${lib.optionalString (xcodeMasId != null) ''
        if [ ! -d /Applications/Xcode.app ]; then
          echo >&2 "Xcode: /Applications/Xcode.app missing — mas install ${toString xcodeMasId} as ${brewUser}"
          # Same privilege model as brew bundle: primary user + mas on PATH.
          if ! PATH="${brewPrefix}/bin:${lib.makeBinPath [ pkgs.mas ]}:$PATH" \
            /usr/bin/sudo --preserve-env=PATH --user=${lib.escapeShellArg brewUser} --set-home \
            ${masBin} install ${toString xcodeMasId}; then
            echo >&2 "warning: Xcode mas install failed (Apple ID / network?). brew bundle may still install it later; license accept below is best-effort."
          fi
        fi
      ''}

      # Prefer full Xcode.app developer dir when present.
      if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        /usr/bin/xcode-select -s /Applications/Xcode.app/Contents/Developer 2>/dev/null || true
      fi

      xcb=""
      if [ -x /usr/bin/xcodebuild ]; then
        xcb=/usr/bin/xcodebuild
      elif [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
        xcb=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
      fi

      if [ -n "$xcb" ]; then
        # Idempotent: `check` exits 0 when already accepted.
        if ! "$xcb" -license check >/dev/null 2>&1; then
          echo >&2 "Xcode: accepting license (operator accepts Apple SDKs terms via this config)"
          if ! "$xcb" -license accept; then
            echo >&2 "warning: xcodebuild -license accept failed; Homebrew formulae that need the SDK may still fail"
          else
            echo >&2 "Xcode: license accepted"
          fi
        else
          echo >&2 "Xcode: license already accepted"
        fi
      else
        echo >&2 "Xcode: no xcodebuild yet — skip license (install Xcode / CLT, then re-activate)"
      fi
    '';
  };
}
