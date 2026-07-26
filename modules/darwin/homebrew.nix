# Declarative Homebrew FRAMEWORK for the Mac (sourced from ~/Brewfile).
# nix-homebrew (./nix-homebrew.nix) installs brew itself; this module owns only
# HOW Homebrew is configured — `enable`, `onActivation` (lean cleanup), and
# `taps`. The concrete WHICH-apps lists (`brews`/`casks`/`masApps`) are set
# PER HOST in hosts/<host>.nix, so each darwin host (macos, macvm, …) can carry
# a different app set while sharing this framework. (Nix list options merge, so
# lists could never *differ* if they lived here — only grow.)
#
# What is DELIBERATELY NOT installed via Homebrew on any host (nixpkgs/Home
# Manager is the single source, and a duplicate on PATH causes buildEnv
# collisions): aws-cdk, awscli, make, node (unversioned), uv, gh, git-lfs, the
# claude-code cask, and 6 font casks — see modules/shared/home.nix. direnv was
# dropped from the repo entirely; reintroduce deliberately if a devShell needs it.
_:

{
  homebrew = {
    enable = true;

    # Lean activation: cleanup = "uninstall" removes any installed brew/cask/tap
    # not declared by the host (but never touches the App Store apps `zap` would
    # also wipe app data for — "uninstall" is the safer of the two enforcing
    # modes). autoUpdate/upgrade stay off so a rebuild never silently bumps versions.
    onActivation = {
      autoUpdate = false;
      upgrade = false;
      cleanup = "uninstall";
    };

    # ---- Taps --------------------------------------------------------------
    # No third-party taps. escrcpy (viarotel-org/escrcpy) was removed — its cask
    # emitted a deprecated `depends_on macos:` warning on every activation.
    # nats-server is homebrew-core, so no tap is needed. (runpodctl comes from
    # nixpkgs via home.nix, not a tap — Homebrew now refuses untrusted taps.)
    taps = [ ];

    # ---- brews / casks / masApps ------------------------------------------
    # Set per host in hosts/<host>.nix (e.g. hosts/macos.nix, hosts/macvm.nix).
  };
}
