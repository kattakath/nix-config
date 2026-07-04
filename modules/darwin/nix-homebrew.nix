# Installs Homebrew ITSELF at the arch-correct prefix, beneath nix-darwin's
# built-in `homebrew.*` module (./homebrew.nix), which still owns the
# taps/brews/casks. Shared by both Macs; nix-homebrew auto-selects the prefix
# from the host platform — nixcon (aarch64) → /opt/homebrew, nixtel (x86_64) →
# /usr/local — so no per-host branching is needed (mkDarwin sets hostPlatform).
{ userName, ... }:
{
  nix-homebrew = {
    enable = true; # install/manage brew at the host's default (arch-correct) prefix
    user = userName; # account that owns the prefix directories
    # nixtel is NATIVE Intel (not Rosetta) and nixcon needs no x86 brew; the
    # module also asserts enableRosetta => isAarch64, so it must stay false here.
    enableRosetta = false;
    # Adopt nixcon's already-installed /opt/homebrew in place on first switch
    # (removes only the brew-repo metadata, not installed packages) so activation
    # isn't blocked by a pre-existing Homebrew. nixtel gets a fresh /usr/local.
    autoMigrate = true;
    # Keep `brew tap`/`brew update` working; avoids pinning the huge
    # homebrew-core/homebrew-cask trees as flake inputs (default).
    mutableTaps = true;
  };
}
