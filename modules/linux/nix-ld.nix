# Home-Manager nix-ld shim — sets NIX_LD / NIX_LD_LIBRARY_PATH from Home Manager
# so dynamically-linked, non-Nix binaries (VS Code Server, prebuilt language
# servers, downloaded toolchains) find a glibc loader without root.
#
# OWNERSHIP — read before "fixing" this:
#   On NixOS hosts (nixbox, nixrpi) the native `programs.nix-ld` module
#   (modules/nixos/core.nix) owns nix-ld and now carries the `libraries` list;
#   it is the single source of truth there. THIS shim is therefore GATED OFF on
#   NixOS and fires ONLY for standalone Home Manager on non-NixOS Linux (Ubuntu,
#   Codespaces, etc.), where `programs.nix-ld` does not exist and would fail
#   evaluation with "The option `programs.nix-ld' does not exist".
#
#   nix-ld's runtime contract is two env vars:
#     NIX_LD                  → path to the dynamic loader (ld-linux)
#     NIX_LD_LIBRARY_PATH     → extra shared libraries to expose
#   Setting them from Home Manager is the portable, standalone-correct way to
#   get the same effect without root or a NixOS system rebuild.
#
#   `hmStandalone` selects that path: it defaults to false (optional arg, so the
#   NixOS/darwin home.nix imports that don't pass it stay valid), and no in-tree
#   host sets it true yet — a future non-NixOS standalone-HM host would.
{
  pkgs,
  lib,
  hmStandalone ? false,
  ...
}:

let
  # Libraries most prebuilt Linux binaries expect at runtime.
  nixLdLibraries = with pkgs; [
    stdenv.cc.cc # libstdc++, libgcc_s
    glibc
    zlib
    openssl
    curl
    util-linux
    libGL
  ];
in
{
  # Fires only for standalone Home Manager on non-NixOS Linux; inert on NixOS
  # hosts (native module owns nix-ld there) and on darwin.
  config = lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && hmStandalone) {
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
