# osConfig -> string: the Homebrew prefix every runtime brew path is built from.
#
# nix-darwin's `homebrew.prefix` (`brew --prefix`) when this profile is embedded
# via home-manager.darwinModules. A NixOS host, a standalone home-manager build
# and the flake's own `packages` output have no osConfig.homebrew, so they get
# nix-darwin's aarch64 default — the fleet is aarch64-only, and only macos-gated
# code ever runs a path built from it.
#
# NOT auto-imported (see ./is-macos-host.nix). Consumers `import` it explicitly.
osConfig: osConfig.homebrew.prefix or "/opt/homebrew"
