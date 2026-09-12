# Eval check, carried over from the satellite flake's own
# `checks.module-evaluates`: a throwaway macOS home-manager config that proves
# the module wires `$BASH_ENV` and emits a loader carrying the
# one-time-per-tree sentinel and the `secret` shell function.
#
# `module` and `home-manager` are ARGUMENTS, not `../module.nix` / `inputs`. A
# capsule is entered through its flake-module.nix and reached downward from
# there; a leaf that imported upward would break the invariant
# ast-grep/rules/capsule-must-not-reach-out.yml enforces (see the header of
# ../flake-module.nix). `home-manager` is an argument for the same reason the
# firmware-secrets capsule's own check takes `nixpkgs`:
# `homeManagerConfiguration` lives on the FLAKE's `lib`, not on `pkgs.lib`.
#
# THE LITERAL `.config/secrets/loader.sh` BELOW IS THE POINT, not laziness. It
# pins the DEFAULT of `programs.keychainSecrets.loaderRelPath`, which
# modules/darwin/core.nix derives `launchd.user.envVariables.BASH_ENV` from BY
# REFERENCE — so a silent change to that default would move the GUI/launchd half
# of the loader without moving the shell half, and nothing else would notice.
# Reading the option back here instead would make the assertion tautological.
#
# `homeDir` is a single binding rather than an inline literal because
# home-manager's `home.homeDirectory` must be ABSOLUTE (it is the one value that
# cannot be $HOME-relative), and a second occurrence spelled `/Users/tester/…`
# would trip ast-grep/rules/nix-hardcoded-home-path.yml — correctly, since that
# rule cannot know a fixture home from a real one. One binding, no interpolated
# `/Users/<name>/` anywhere, same assertion.
{
  home-manager,
  pkgs,
  module,
}:
let
  homeDir = "/Users/tester";
  hm = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      module
      {
        home.username = "tester";
        home.homeDirectory = homeDir;
        home.stateVersion = "24.05";
        programs.keychainSecrets.enable = true;
      }
    ];
  };
  loader = hm.config.home.file.".config/secrets/loader.sh".source;
in
pkgs.runCommand "keychain-secrets-eval" { } ''
  test "${hm.config.home.sessionVariables.BASH_ENV}" = "${homeDir}/.config/secrets/loader.sh"
  grep -q "__SECRETS_KEYCHAIN_LOADED" ${loader}
  grep -q "secret()" ${loader}
  echo ok > "$out"
''
