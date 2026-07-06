# Home-Manager nix-ld shim — sets NIX_LD / NIX_LD_LIBRARY_PATH from Home Manager
# so dynamically-linked, non-Nix binaries (VS Code Server, prebuilt language
# servers, downloaded toolchains) find a glibc loader without root.
#
# OWNERSHIP — read before "fixing" this:
#   On NixOS hosts (nixpi, nixvm) the native `programs.nix-ld` module
#   (modules/nixos/core.nix) owns nix-ld and now carries the `libraries` list;
#   it is the single source of truth there. THIS shim is therefore GATED OFF on
#   NixOS and fires ONLY for standalone Home Manager on non-NixOS Linux (Ubuntu,
#   Codespaces, etc.), where `programs.nix-ld` does not exist and would fail
#   evaluation with "The option `programs.nix-ld' does not exist".
#
#   Setting NIX_LD / NIX_LD_LIBRARY_PATH from Home Manager is the portable,
#   standalone-correct way to get nix-ld's effect without root or a system rebuild.
#
#   `hmStandalone` selects that path. It is a declared module option (NOT a
#   function-arg default): the module system resolves named function arguments
#   from `_module.args` and does not honor a `? false` fallback for a path-
#   imported module, so a plain arg default throws "attribute 'hmStandalone'
#   missing" on every consumer. Declaring it as an option with `default = false`
#   keeps every current import (NixOS + darwin) valid and inert; a future
#   non-NixOS standalone-HM host opts in with `hmStandalone = true;` (none
#   in-tree today).
{
  pkgs,
  lib,
  config,
  ...
}:

let
  # Libraries most prebuilt Linux binaries expect at runtime — shared source of
  # truth (same set the native NixOS module and the devcontainer image use).
  nixLdLibraries = import ../shared/nix-ld-libraries.nix pkgs;
in
{
  options.hmStandalone = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Enable the Home-Manager nix-ld shim. Set true only on a standalone
      Home-Manager host on non-NixOS Linux, where `programs.nix-ld` does not
      exist. On NixOS the native `programs.nix-ld` module owns nix-ld, so this
      stays false and the shim is inert.
    '';
  };

  # Fires only for standalone Home Manager on non-NixOS Linux; inert on NixOS
  # hosts (native module owns nix-ld there) and on darwin.
  config = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && config.hmStandalone) {
    home.sessionVariables = {
      # The glibc dynamic loader the patched binaries should invoke.
      NIX_LD = "${pkgs.stdenv.cc.bintools.dynamicLinker}";
      # Search path the loader exposes to those binaries.
      NIX_LD_LIBRARY_PATH = lib.makeLibraryPath nixLdLibraries;
    };

    # Make the loader libs part of the profile so the paths above resolve.
    home.packages = nixLdLibraries;
  };
}
