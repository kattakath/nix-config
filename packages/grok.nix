# xAI's `grok` CLI, pinned from the vendor's own public artifact bucket.
#
# WHY A PREBUILT BINARY — the first in this tree. NOT because there is no
# source: xai-org/grok-build is Apache-2.0 Rust with a Cargo.lock (that claim
# was true when this file was written and is now false — corrected 2026-09-29).
# The reasons that survive are the two below: building from source cannot
# reproduce xAI's Developer ID SIGNATURE, which `dontFixup` exists to preserve,
# and a Rust toolchain in the closure buys nothing this fleet wants. The
# alternative is what this replaces: the vendor's `curl … | bash` installer
# dropping a self-updating binary into ~/.grok/bin, per account, outside both
# the store and Homebrew — invisible to `nix flake check`, unversioned in git,
# and needing a separate install for every user on the machine.
#
# WHY IT IS SAFE TO PIN. The artifact URL is stable and public
# (`.../cli/grok-<version>-<platform>`, read out of the vendor's install.sh
# rather than guessed), and `hash` below is the operator's own SRI pin, not a
# checksum the vendor publishes — xAI ships none (both .sha256 spellings 404).
#
# HOW A BUMP IS VERIFIED. The original 1.0.30 pin was byte-compared against the
# copy the vendor's installer had left in ~/.grok/downloads. That check is only
# available for a version the updater happened to fetch, and it is weak anyway:
# both copies come from the same bucket, so it proves transport, not origin.
# Since 1.0.45 the check is the Mach-O SIGNATURE, which is strictly stronger —
# it proves xAI signed these exact bytes no matter how they arrived:
#
#   codesign --verify --strict <artifact>   # exit 0
#   codesign -dvvv <artifact> 2>&1 | grep Authority
#     Authority=Developer ID Application: X.AI Corporation (5Y6N3AJ54S)
#     Authority=Developer ID Certification Authority
#     Authority=Apple Root CA
#
# Identifier must read `xai-grok-pager` and TeamIdentifier `5Y6N3AJ54S`. Run
# both on every bump; a signature that does not chain to Apple Root CA is a
# stop, not a warning.
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
  version = "1.0.45";
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
    hash = "sha256-fIUKl/kA/uYLTL5rSqLYc6DO7J0RQw46eRdyjoxgkeE=";
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
