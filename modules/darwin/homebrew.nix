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
# claude-code cask, 6 font casks, pandoc, and poppler — see modules/shared/home.nix.
_:

{
  homebrew = {
    enable = true;

    # Lean activation: cleanup = "uninstall" removes brew/cask/tap **and** MAS
    # apps not declared in the host's Brewfile (so undeclared App Store apps
    # installed by hand get uninstalled on next switch — list them in masApps
    # or reinstall after rebuild). autoUpdate/upgrade stay off so a rebuild
    # never silently bumps versions.
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
    # masApps: **macos only** — macvm has no Apple ID / App Store login, so any
    # MAS install fails activation there. Keep hosts/macvm.nix masApps = { }.
  };
}
