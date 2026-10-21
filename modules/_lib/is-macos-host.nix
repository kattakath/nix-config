# osConfig -> bool: is this Home Manager profile running on the operator's Mac?
#
# ONE definition for the four home modules that gate macos-only behaviour on it
# (default.nix, macos-user-agents.nix, spotlight-actions.nix,
# tor-browser-backup-exclusion.nix); each used to spell the same test itself.
#
# Reads `local.operatorHost` (modules/darwin/operator-host.nix), set only in
# hosts/macos.nix — NOT `networking.hostName == "macos"`, which a template
# consumer can legitimately name their own Mac. `or false` because the NixOS
# hosts and a standalone home-manager evaluation declare no such option.
#
# NOT auto-imported — `modules/_lib/` is excluded from import-tree by convention
# (see ./nix-ld-libraries.nix). Consumers `import` it explicitly.
osConfig: osConfig.local.operatorHost or false
