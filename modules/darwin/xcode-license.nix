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
# upstream-first, two halves:
#   INSTALL — upstream option nix-darwin.programs.mas exists → using it (pinned
#   modules/programs/mas.nix:149-176: `packages.<name> = <id>` installed as the
#   mas user via the same sudo model this file used to hand-roll, :41-45, with an
#   idempotent `is_installed` guard, :98-114; emitted as activationScripts.mas,
#   :207, which activation-scripts.nix:137 runs immediately BEFORE homebrew).
#   Two traps: `programs.mas.update` defaults TRUE (:178-185) and would run
#   `mas update` on every activation, so it is forced off here — versions belong
#   to the operator (modules/darwin/homebrew.nix); and Xcode must ALSO stay in
#   `homebrew.masApps`, or brew bundle's cleanup uninstalls it (homebrew.nix:196).
#   LICENCE — grepped nix-darwin/modules for `license accept|xcodebuild`: nothing
#   beyond the App Store id examples, so acceptance stays custom, injected into
#   nix-darwin's own activation ordering rather than a new hook.
#
# Fix
# ---
# `programs.mas` installs Xcode (when `homebrew.masApps.Xcode` is set) in the
# `mas` activation step; the licence accept is injected into
# `system.activationScripts.homebrew` via `lib.mkBefore`, so it runs as root
# *immediately before* the brew-bundle body (activation order is fixed in
# nix-darwin: … → mas → homebrew → postActivation).
#
# Scoped to `networking.hostName == "macos"`.
{
  config,
  lib,
  ...
}:

let
  cfg = config.homebrew;
  # Present only when the host declares Xcode in masApps (hosts/macos.nix).
  xcodeMasId = cfg.masApps.Xcode or null;
  enabled = cfg.enable && config.networking.hostName == "macos";
in
{
  config = lib.mkIf enabled {
    programs.mas = {
      enable = true;
      packages = lib.optionalAttrs (xcodeMasId != null) { Xcode = xcodeMasId; };
      # Never `mas update` at activation — see the header.
      update = false;
    };

    # ---- PRE-FLIGHT: a signed-out App Store must abort BEFORE any mutation ---
    #
    # Upstream's mas activation script does `exit 0` when `mas list` reports
    # "not signed in" (pinned modules/programs/mas.nix:56-58). That `exit` is
    # TOP-LEVEL in $systemConfig/activate, so it ends the WHOLE activation with
    # status 0 — skipping brew bundle, BOTH home-manager profiles, and the
    # closing `ln -sfn … /run/current-system`. The system profile advances while
    # /run/current-system, the current-system GC root and therefore PATH stay on
    # the previous generation, and `darwin-rebuild` reports SUCCESS. It is the
    # one silent-success path in this fleet, and it fires on exactly the case
    # this flake exists to serve: a freshly wiped Mac that has not signed in yet.
    #
    # `system.checks.text` is the sanctioned slot for a pre-mutation refusal: it
    # is compiled into the same activate script but runs near its TOP (upstream
    # activation-scripts.nix orders `checks` right after preActivation), and
    # `darwin-rebuild check` runs exactly this block, so it doubles as a
    # rehearsal. Refusing here converts a silent half-apply into a loud no-op.
    #
    # Gated on `packages != { }` so it only fires when mas actually has work —
    # i.e. when the host declares Xcode in masApps. `|| true` on the sudo so a
    # missing/odd user cannot itself abort the check.
    system.checks.text = lib.mkAfter (
      lib.optionalString (config.programs.mas.packages != { }) ''
        masOut=$(
          sudo --preserve-env=PATH --set-home \
            --user=${lib.escapeShellArg config.programs.mas.user} \
            ${lib.getExe config.programs.mas.package} list 2>&1
        ) || true
        if printf '%s' "$masOut" | /usr/bin/grep -qi "not signed in"; then
          printf >&2 '\e[1;31merror: the App Store is not signed in, aborting activation\e[0m\n'
          printf >&2 'programs.mas is installing %s, and upstream would `exit 0` mid-activation\n' \
            ${lib.escapeShellArg (toString (builtins.attrNames config.programs.mas.packages))}
          printf >&2 'leaving the system profile advanced but /run/current-system stale.\n'
          printf >&2 'Sign in as %s (App Store > Sign In), then re-run.\n' \
            ${lib.escapeShellArg config.programs.mas.user}
          exit 2
        fi
      ''
    );

    system.activationScripts.homebrew.text = lib.mkBefore ''
      # ---- Xcode presence + license (must precede brew bundle) ----------------
      echo >&2 "Xcode: ensuring app + license before Homebrew bundle..."


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
