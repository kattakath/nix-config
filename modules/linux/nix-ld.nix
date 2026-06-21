# Linux-only: make dynamically-linked, non-Nix binaries (VS Code Server,
# prebuilt language servers, downloaded toolchains) find a glibc loader.
#
# ARCHITECTURAL NOTE — read before "fixing" this:
#   `programs.nix-ld.enable` is a NixOS *system* module option. It does NOT
#   exist in standalone Home Manager and will fail evaluation with
#   "The option `programs.nix-ld' does not exist" on exactly the Ubuntu/Pi
#   hosts this file targets. nix-ld's runtime contract is two env vars:
#     NIX_LD                  → path to the dynamic loader (ld-linux)
#     NIX_LD_LIBRARY_PATH     → extra shared libraries to expose
#   The nix-ld shim (installed system-wide, or the binary's own loader) reads
#   these. Setting them from Home Manager is the portable, standalone-correct
#   way to get the same effect without root or a NixOS system rebuild.
#
#   If this host happens to be NixOS, enable the real module there instead:
#     programs.nix-ld.enable = true;
{ pkgs, lib, ... }:

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
  # Guard the whole module so it is inert if accidentally imported on darwin.
  config = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
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
