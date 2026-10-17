# osConfig -> bool: is this Home Manager profile running on the operator's Mac?
#
# ONE definition for the four home modules that gate macos-only behaviour on it
# (default.nix, macos-user-agents.nix, spotlight-actions.nix,
# tor-browser-backup-exclusion.nix); each used to spell the same test itself.
# `or ""` because a standalone home-manager evaluation has no osConfig hostName.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly.
osConfig: (osConfig.networking.hostName or "") == "macos"
