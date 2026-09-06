# Declarative Homebrew FRAMEWORK for the Mac (nix-darwin renders the Brewfile
# into the STORE and passes it as `brew bundle --file=`; there is no ~/Brewfile).
# nix-homebrew (./nix-homebrew.nix) installs brew itself; this module owns only
# HOW Homebrew is configured — `enable`, `onActivation` (lean cleanup), and
# `taps`. The concrete WHICH-apps lists (`brews`/`casks`/`masApps`) are set
# PER HOST in hosts/<host>.nix, so each darwin host can carry
# a different app set while sharing this framework. (Nix list options merge, so
# lists could never *differ* if they lived here — only grow.)
#
# What is DELIBERATELY NOT installed via Homebrew on any host (nixpkgs/Home
# Manager is the single source, and a duplicate on PATH causes buildEnv
# collisions): aws-cdk, awscli, make, node (unversioned), uv, gh, git-lfs, the
# claude-code cask, 6 font casks, pandoc, poppler, and `mas` — see
# modules/shared/home.nix, and modules/darwin/core.nix for `mas` (which the
# fleet already consumed as `pkgs.mas` from xcode-license.nix's activation).
_:

{
  homebrew = {
    enable = true;

    # Lean activation: cleanup = "uninstall" removes brew/cask/tap **and** MAS
    # apps not declared in the host's Brewfile (so undeclared App Store apps
    # installed by hand get uninstalled on next switch — list them in masApps
    # or reinstall after rebuild). autoUpdate/upgrade stay off so a rebuild
    # never silently bumps versions.
    # `--quiet` and HOMEBREW_NO_COLOR exist to make activation output READABLE,
    # not to change what gets installed. Measured 2026-09-06 on a converged
    # Brewfile (76 entries, nothing to install), `brew bundle` on a tty:
    #   default        2058 bytes, 95 ANSI escapes
    #   --quiet         620 bytes, 93 escapes   <- drops 76 "Using <cask>" lines
    #   +NO_COLOR       620 bytes, 62 escapes   <- drops the SGR colour pairs
    # The residual 62 are `ESC[?2026h/l` (DECSET 2026, synchronized output) from
    # bundle/parallel_installer.rb's `clear_tty_line`, which opens /dev/tty
    # DIRECTLY. No env var reaches it (NO_COLOR, HOMEBREW_NO_COLOR, TERM=dumb and
    # HOMEBREW_DOWNLOAD_CONCURRENCY=1 were each measured to change nothing) and
    # redirecting stdout does not either — it is unfixable from this side while a
    # controlling terminal exists. Don't retry those levers.
    #
    # extraEnv is the ONLY way to reach brew's environment here: nix-darwin runs
    # it as `sudo --preserve-env=PATH --user=... env <extraEnv> brew bundle`
    # (nix-darwin modules/homebrew.nix), so sudo's env_reset drops everything the
    # operator's shell exports.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "uninstall";
      extraFlags = [ "--quiet" ];
      extraEnv.HOMEBREW_NO_COLOR = "1";
    };

    # ---- Taps --------------------------------------------------------------
    # Exactly one third-party tap, and it is a DELIBERATE RE-ADOPTION (2026-08-31)
    # of one this repo removed on 2026-07-08 — so do not "clean it up" as leftover
    # drift. escrcpy is the graphical scrcpy frontend (Electron; hosts/macos.nix
    # casks) and ships NOWHERE else: absent from homebrew-core AND from nixpkgs,
    # with only an upstream .dmg otherwise. Since every other GUI app here arrives
    # as a cask or a masApp, the tap is what keeps this one declarative instead of
    # a hand-dragged .app no `cleanup` would ever reclaim.
    #
    # Two costs accepted knowingly, both re-verified against the tap at v3.0.8:
    #   - `depends_on macos: :catalina` is STILL in the cask, so the deprecation
    #     warning that motivated the 2026-07-08 removal is back on every
    #     activation. It is cosmetic — not a failure — and staying declarative was
    #     judged worth it.
    #   - Gatekeeper never evaluates the app: upstream ships it unsigned, so a
    #     quarantined copy is reported "damaged and can't be opened" and will not
    #     launch at all. The cask therefore carries a `postinstall` that strips the
    #     quarantine flag (hosts/macos.nix) — that hook is load-bearing, not
    #     polish. The measurement, the rejected `args.no_quarantine` alternative,
    #     and the security tradeoff are all recorded at that cask entry; read it
    #     before touching either flag.
    #
    # Workable only because nix-homebrew sets mutableTaps = true (./nix-homebrew.nix)
    # — otherwise a tap must be pinned as a flake input. Framework-level per this
    # file's ownership split — any future darwin host gets the tap but not the cask (its
    # casks list is its own); a tap with nothing installed from it is inert.
    #
    # A THIRD requirement, and the one that actually broke first: Homebrew 6.0.0
    # turned on HOMEBREW_REQUIRE_TAP_TRUST by default, so brew REFUSES TO LOAD a
    # non-official tap's casks until that tap is trusted — activation dies with
    # "Refusing to load cask … from untrusted tap". A bare-string tap entry is
    # therefore not enough on its own: you get a tap that clones and a cask that
    # is never read. `trusted = true` is nix-darwin's own answer (it writes
    # `trusted: true` onto the Brewfile's `tap` line), so ANY non-official tap
    # added here needs it — do not hand-roll a `brew trust` activation step, and
    # note that the *cask* line's own `trusted:` does NOT cover the tap.
    #
    # nats-server is homebrew-core, so no tap is needed. (runpodctl comes from
    # nixpkgs via home.nix, not a tap.)
    taps = [
      {
        name = "viarotel-org/escrcpy";
        trusted = true;
      }
    ];

    # ---- brews / casks / masApps ------------------------------------------
    # Set per host in hosts/<host>.nix (e.g. hosts/macos.nix).
    # masApps: **macos only** — a GUI-less/sandbox host has no App Store login, so any
    # MAS install fails activation there.
  };
}
