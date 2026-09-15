# xAI's `grok` CLI, pinned from the vendor's own public artifact bucket.
#
# WHY A PREBUILT BINARY — the first in this tree. grok is closed-source; xAI
# publishes only signed Mach-O artifacts, so there is no source to build. The
# alternative is what this replaces: the vendor's `curl … | bash` installer
# dropping a self-updating binary into ~/.grok/bin, per account, outside both
# the store and Homebrew — invisible to `nix flake check`, unversioned in git,
# and needing a separate install for every user on the machine.
#
# WHY IT IS SAFE TO PIN. The artifact URL is stable and public
# (`.../cli/grok-<version>-<platform>`, read out of the vendor's install.sh
# rather than guessed), and `hash` below is the operator's own SRI pin, not a
# checksum the vendor publishes — xAI ships none (both .sha256 spellings 404).
# The pin was cross-checked against the copy the vendor's installer had already
# placed in ~/.grok/downloads: byte-identical, which is what makes this a
# REPRODUCTION of a verified install rather than a fresh act of trust.
#
# THE SELF-UPDATER IS DELIBERATELY DEFEATED. grok normally downloads new
# versions into ~/.grok/downloads and re-points the ~/.grok/bin/grok symlink.
# From the store it cannot: the store is read-only, and hosts/macos.nix drops
# the `$HOME/.grok/bin` PATH entry so a stale per-user copy cannot shadow this
# one. Updating is therefore a `version` + `hash` bump here, reviewed in git —
# which is the entire point of moving it in. Expect the updater to complain.
#
# PER-USER STATE IS UNAFFECTED, which is what makes sharing one binary correct:
# agent_id, active_sessions.json, sandbox.toml and installed-plugins all live in
# ~/.grok, not next to the executable. Two accounts share the code and keep
# separate identities.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "1.0.30";
  # The only platform this fleet has. aarch64-darwin is asserted through
  # meta.platforms rather than branched on: a wrong-arch build should fail
  # loudly at eval, not download an x86_64 binary and run it under Rosetta.
  platform = "macos-aarch64";
in
stdenvNoCC.mkDerivation {
  pname = "grok";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/grok-build-public-artifacts/cli/grok-${version}-${platform}";
    hash = "sha256-1TtuVD5IJxYjZ0iRQzHbUBRcaWrHr5Hx697c9WVM/ss=";
  };

  # A bare executable, not an archive.
  dontUnpack = true;

  # LOAD-BEARING. The binary carries xAI's Developer ID signature
  # (TeamIdentifier 5Y6N3AJ54S, identifier `xai-grok-pager`). nixpkgs' default
  # fixup strips and re-writes Mach-O headers, which invalidates that signature
  # and leaves Gatekeeper killing the process on launch. Copy the bytes, change
  # nothing.
  dontFixup = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/grok"
    # The vendor's installer exposes the same binary under both names and the
    # plugin surface calls the second one; mirror that rather than making
    # callers care which they got.
    ln -s grok "$out/bin/agent"
    runHook postInstall
  '';

  meta = {
    description = "xAI's Grok coding agent CLI (vendor-signed prebuilt)";
    homepage = "https://docs.x.ai/build/overview";
    # Closed-source vendor binary redistributed from xAI's own public bucket.
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "grok";
  };
}
