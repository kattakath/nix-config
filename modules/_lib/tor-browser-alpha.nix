# tor-browser on aarch64-linux, from the ALPHA channel — an overlay, as DATA.
# Consumed by modules/nixos/desktop-vm.nix (nixvm, inside its `mkIf`) and by
# hosts/nixos.nix. One copy, so a bump moves both.
#
# WHY an overlay at all: the pinned nixpkgs' tor-browser THROWS at eval on
# aarch64-linux — `src = sources.${stdenv.hostPlatform.system} or (throw
# "unsupported system: ...")` — because upstream STABLE ships no aarch64 Linux
# tarball (15.0.25 on 2026-10-17: linux-x86_64 and i686 only, aarch64 404).
# `tor-browser-bundle-bin` is a hard alias throw, not an alternative. nixpkgs
# will not package the aarch64 build until 16.0 goes stable
# (NixOS/nixpkgs#491286, still open 2026-10-17), so there is no upstream
# option, package or flake to prefer — this is the one lane.
#
# WHY overrideAttrs and NOT `.override { sources = ...; }`: `sources` is a
# `let` binding inside package.nix, not a function argument, so it is not
# overridable. Replacing `src` directly is the only reachable surface — and it
# means `meta.platforms` (`lib.attrNames sources`) must be widened by hand or
# nixpkgs refuses the host platform.
#
# THE ALPHA MOVED torrc-defaults. Since 16.0a13 the tarball has
# `TorBrowser/Tor/torrc-defaults` and `TorBrowser/Tor/geoip{,6}` where 15.x had
# `TorBrowser/Data/Tor/...` (verified by `tar tf` on 16.0a13 and again on
# 16.0a14). The stock buildPhase's `--replace-fail` would abort on the missing
# file, so the path prefix is rewritten in the phase text — one substitution
# covers all four uses (substituteInPlace, the torrc-defaults_path lockPref, and
# both GeoIP lines).
#
# Everything else in that derivation is arch-generic (autoPatchelfHook + a
# makeWrapper LD_LIBRARY_PATH), which is why this works at all.
#
# KNOWN COSMETIC ROT: `meta.changelog` is baked from the let-bound 15.0.x
# version and still points at the maint-15.0 branch.
#
# BUMPING: alpha releases are short-lived and dist.torproject.org keeps only the
# current one, so a stale pin becomes a 404 fetch (16.0a13 did, by 2026-10-17);
# the archive.torproject.org URL is the fallback that keeps an old pin
# building. Re-point version + hash from https://dist.torproject.org/torbrowser/
# (`nix store prefetch-file`), re-check the tarball layout above, and DELETE
# this file once nixpkgs ships 16.0 stable with aarch64.
_final: prev: {
  tor-browser = prev.tor-browser.overrideAttrs (old: {
    version = "16.0a14";
    src = prev.fetchurl {
      urls = [
        "https://dist.torproject.org/torbrowser/16.0a14/tor-browser-linux-aarch64-16.0a14.tar.xz"
        "https://archive.torproject.org/tor-package-archive/torbrowser/16.0a14/tor-browser-linux-aarch64-16.0a14.tar.xz"
      ];
      hash = "sha256-v/bCepJdx8kIzZHu9UPacGMrgTxqC5Zgsj9lrC10uqE=";
    };
    buildPhase =
      builtins.replaceStrings [ "TorBrowser/Data/Tor/" ] [ "TorBrowser/Tor/" ]
        old.buildPhase;
    meta = old.meta // {
      platforms = old.meta.platforms ++ [ "aarch64-linux" ];
    };
  });
}
