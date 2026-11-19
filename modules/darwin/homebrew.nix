# Declarative Homebrew FRAMEWORK for the Mac (nix-darwin renders the Brewfile
# into the STORE and passes it as `brew bundle --file=`; there is no ~/Brewfile).
# nix-homebrew (./nix-homebrew.nix) installs brew itself; this module owns only
# HOW Homebrew is configured — `enable`, `onActivation` (lean cleanup), and
# `taps`, plus the one cross-host cask below (`firefox`). The concrete WHICH-apps
# lists (`brews`/`casks`/`masApps`) are otherwise set
# PER HOST in hosts/<host>.nix, so each darwin host can carry
# a different app set while sharing this framework. (Nix list options merge, so
# lists could never *differ* if they lived here — only grow.)
#
# What is DELIBERATELY NOT installed via Homebrew on any host (nixpkgs/Home
# Manager is the single source, and a duplicate on PATH causes buildEnv
# collisions): whatever a Nix module already installs — read those, not a list
# here. `mas` is nix-darwin's `programs.mas` (xcode-license.nix).
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

    # Lean activation: cleanup = "zap" runs `brew bundle --cleanup --zap`, so anything
    # not declared in the host's Brewfile is removed AND, for a cask, its trace files
    # (preferences, caches, support dirs) go with it — the operator's rule is that
    # anything undeclared is purged without a trace. Precedent: nix-darwin
    # `modules/homebrew.nix` `onActivation.cleanup` (enum none/check/uninstall/zap).
    # THE CONSEQUENCE THAT BITES: zap moves an undeclared cask's app and user
    # data (a browser profile, say) to the Trash on the next activate: gone for good
    # once the Trash is emptied. Declare the app, or
    # export its data, BEFORE undeclaring it.
    # Mac App Store apps: zap behaves exactly as uninstall did. The pinned
    # nix-darwin passes `--zap --force-cleanup` where it passed `--force-cleanup`,
    # and `--zap` only extends the removal for casks, so undeclared MAS apps are
    # still uninstalled and `masApps` still protects the declared ones.
    # Apps installed OUTSIDE Homebrew are invisible to cleanup; fleet-doctor step E10
    # reports them. autoUpdate/upgrade stay off so a rebuild never silently bumps
    # versions.
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
      cleanup = "zap";
      extraFlags = [ "--quiet" ];
    };

    # ---- Taps --------------------------------------------------------------
    # None here: a tap belongs to the host that installs from it (hosts/macos.nix
    # carries escrcpy's), so a template consumer is never handed a trusted
    # third-party tap it installs nothing from.
    #
    # Any non-official tap needs `trusted = true`: Homebrew 6.0.0 turned on
    # HOMEBREW_REQUIRE_TAP_TRUST, so brew refuses to load an untrusted tap's casks
    # ("Refusing to load cask … from untrusted tap"). That is nix-darwin's own
    # answer (it writes `trusted: true` onto the Brewfile's `tap` line); do not
    # hand-roll a `brew trust` step, and note the cask line's own `trusted:` does
    # NOT cover the tap. Taps work unpinned only because nix-homebrew sets
    # mutableTaps = true (./nix-homebrew.nix).

    # ---- brews / casks / masApps ------------------------------------------
    # Per-host lists live in hosts/<host>.nix (e.g. hosts/macos.nix); the list
    # options MERGE, so what is declared below lands on EVERY darwin host that
    # imports this module (template consumers included) and is protected from
    # `cleanup = "zap"` there.
    #
    # Firefox: the vendor-signed `.app` from the cask, not nixpkgs. Measured
    # 2026-11-19 on the pinned nixpkgs for aarch64-darwin: `firefox` and
    # `firefox-bin` have NO cache.nixos.org entry (a local build; the source
    # build is hours of Rust/C++), and a Nix-store `.app` is unreliable for
    # Launch Services/Spotlight. `firefox-esr` is cached but an older line.
    casks = [ "firefox" ];
  };
}
