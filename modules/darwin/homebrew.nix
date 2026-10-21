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
# modules/home/default.nix, and modules/darwin/core.nix for `mas` (which the
# fleet already consumed as `pkgs.mas` from xcode-license.nix's activation).
#
# THE ONE DELIBERATE INVERSION OF THAT PRINCIPLE: `gnupg` IS brewed (2026-10-06).
# Two GnuPG stacks sharing one `~/.gnupg` make which `gpg-agent`/pinentry you get
# a startup-order lottery — so exactly one stack wins, and here it is Homebrew's
# (it holds the operator's keyring; the `gpgfrontend` cask that first pulled it
# in was removed 2026-10-17). Measured:
# brew's gnupg is 2.5.24 (gnupg.org's current stable) while nixpkgs' at this pin
# is 2.4.9, past its 2026-06-30 EOL. Full reasoning and the rejected
# alternatives live with the entries in hosts/macos.nix — do not duplicate it
# here, and do not "clean up" the brew entry without reading it. Revisit only if
# a Nix-BUILT job needs a pinned gnupg; the fix then is `GNUPGHOME` isolation for
# that job, not two stacks sharing the operator's home.
_:

{
  homebrew = {
    enable = true;

    # Lean activation: cleanup = "uninstall" removes brew/cask/tap **and** MAS
    # apps not declared in the host's Brewfile (so undeclared App Store apps
    # installed by hand get uninstalled on next switch — list them in masApps
    # or reinstall after rebuild). autoUpdate/upgrade stay off so a rebuild
    # never silently bumps versions.
    # `--quiet` exists to make activation output READABLE, not to change what
    # gets installed. Measured 2026-09-06 on a converged Brewfile (76 entries,
    # nothing to install), `brew bundle` on a tty:
    #   default   2058 bytes, 95 ANSI escapes
    #   --quiet    620 bytes, 93 escapes   <- drops 76 "Using <cask>" lines
    # What survives is `ESC[?2026h/l` (DECSET 2026, synchronized output) from
    # bundle/parallel_installer.rb's `clear_tty_line`, which opens /dev/tty
    # DIRECTLY, so no env var reaches it: NO_COLOR, HOMEBREW_NO_COLOR, TERM=dumb
    # and HOMEBREW_DOWNLOAD_CONCURRENCY=1 were each measured to change nothing,
    # and redirecting stdout does not either. HOMEBREW_NO_COLOR shaved the SGR
    # pairs (93 -> 62) while leaving the repaint that actually hurts, which is
    # why it is gone rather than kept. The repaint is unfixable from this side
    # while a controlling terminal exists — don't retry those levers.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "uninstall";
      extraFlags = [ "--quiet" ];
    };

    # ---- Taps --------------------------------------------------------------
    # Exactly one third-party tap: our OWN shared tap, ismailkattakath/tap
    # (github.com/ismailkattakath/homebrew-tap — brew maps `<user>/tap` to
    # `homebrew-tap`). It holds every cask this fleet ships that homebrew/cask
    # does not, so a new one is a file in that repo, not a new tap here. It
    # replaced the per-app fork tap `ismailkattakath/escrcpy` (2026-10-21).
    # Do not "clean it up" as leftover drift: each cask in it ships NOWHERE else,
    # and without the tap the app would be a hand-dragged .app no `cleanup` reclaims.
    #
    #   - escrcpy (graphical scrcpy frontend; absent from homebrew-core AND nixpkgs).
    #     Migrated from our fork of viarotel-org/homebrew-escrcpy; the tap's README
    #     lists what diverges. The first divergence: upstream's `depends_on macos: :catalina` is DISABLED in
    #     Homebrew 7 (a hard `brew bundle` failure that aborts activation — why
    #     nix-homebrew sat rev-pinned to brew 6.0.22, kattakath/nix-config#613).
    #     The upstream fix, viarotel-org/homebrew-escrcpy#61, was CLOSED unmerged
    #     (2026-10-10), so the cask stays ours. Cost: no upstream version bumps —
    #     bump `version` + `sha256` in the tap when escrcpy releases, then `git pull`
    #     the installed clone under /opt/homebrew/Library/Taps — `autoUpdate` is off
    #     (above), so nothing else ever moves it and `activate` keeps the old cask.
    #
    # The app is unsigned and not notarized, so Gatekeeper never evaluates it: a
    # quarantined copy will not launch. Each such cask entry therefore
    # carries a `postinstall` that strips the quarantine flag (hosts/macos.nix) —
    # load-bearing, not polish. The measurement, the rejected `args.no_quarantine`
    # alternative, and the security tradeoff are recorded at the escrcpy cask entry;
    # read it before touching either flag.
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
    # nats-server is homebrew-core, so no tap is needed.
    taps = [
      {
        # Our shared tap — see above. Resolves to github.com/ismailkattakath/homebrew-tap.
        name = "ismailkattakath/tap";
        trusted = true;
      }
    ];

    # ---- brews / casks / masApps ------------------------------------------
    # Set per host in hosts/<host>.nix (e.g. hosts/macos.nix).
  };
}
