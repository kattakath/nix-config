# Installs Homebrew ITSELF at the arch-correct prefix, beneath nix-darwin's
# built-in `homebrew.*` module (./homebrew.nix), which still owns the
# taps/brews/casks. nix-homebrew auto-selects the prefix from the host
# platform — this fleet's Mac (aarch64) → /opt/homebrew.
{ userName, ... }:
{
  nix-homebrew = {
    enable = true; # install/manage brew at the host's default (arch-correct) prefix
    user = userName; # account that owns the prefix directories
    # This fleet's Mac needs no x86 brew, so Rosetta stays off; the module also
    # asserts enableRosetta => isAarch64, so it must stay false here.
    enableRosetta = false;
    # Safely adopts a pre-existing /opt/homebrew in place if one is already
    # installed (removes only the brew-repo metadata, not installed packages)
    # so activation isn't blocked by it; a no-op on a clean install with no
    # prior Homebrew present.
    autoMigrate = true;
    # Keep `brew tap`/`brew update` working; avoids pinning the huge
    # homebrew-core/homebrew-cask trees as flake inputs (default).
    mutableTaps = true;
  };
}
