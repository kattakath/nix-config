# Guest agent for Tart VMs (github.com/cirruslabs/tart-guest-agent) — clipboard
# sync (`--run-vdagent`, an in-house SPICE vdagent implementation), `tart exec`
# RPC, and `tart ip --resolver=agent`, bundled under `--run-agent`.
#
# NEITHER nixpkgs NOR a Homebrew tap carries this — cirruslabs publish only a
# GitHub Releases tarball (verified: no `tart-guest-agent` in nixpkgs, no
# `cirruslabs/homebrew-*` formula for it — only the unrelated `homebrew-cli`
# tap for their separate Cirrus CLI). So this derivation fetches the release
# asset directly, ad-hoc-signed (linker-signed) universal arm64/x86_64 binary —
# runs fine unsigned via launchd since Nix-fetched files carry no quarantine
# xattr (the actual Gatekeeper trigger, not the absence of a signature).
#
# Installed + run INSIDE the macvm guest only (hosts/macvm.nix) — never on the
# macos host, which has no VM to be a guest of.
{
  stdenvNoCC,
  fetchurl,
}:
let
  version = "0.11.0";
in
stdenvNoCC.mkDerivation {
  pname = "tart-guest-agent";
  inherit version;

  src = fetchurl {
    url = "https://github.com/cirruslabs/tart-guest-agent/releases/download/v${version}/tart-guest-agent-darwin-all.tar.gz";
    hash = "sha256-KOG2mMcmxfHQ+MnQhrM5D2QH1H4/S4MIHZsqmiofC8c=";
  };

  # The release tarball has no top-level directory (LICENSE/README.md/binary
  # sit flat) — stdenv's unpacker otherwise errors with "produced no directories".
  sourceRoot = ".";

  dontBuild = true;
  dontFixup = true; # skip patchelf/etc — irrelevant + would strip the ad-hoc Mach-O signature

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m755 tart-guest-agent "$out/bin/tart-guest-agent"
    runHook postInstall
  '';

  meta = {
    description = "Tart VM guest agent — clipboard sync (vdagent), tart exec RPC, disk resize";
    homepage = "https://github.com/cirruslabs/tart-guest-agent";
    mainProgram = "tart-guest-agent";
    # Functional Source License 1.1, ALv2 Future (source-available; converts to
    # Apache-2.0 two years after each release) — not a standard OSI license, so
    # no matching lib.licenses.* entry; not free but permits this personal,
    # non-competing use.
    license = {
      fullName = "Functional Source License 1.1, ALv2 Future License";
      url = "https://github.com/cirruslabs/tart-guest-agent/blob/main/LICENSE";
      free = false;
    };
    platforms = [
      "aarch64-darwin"
      "x86_64-darwin"
    ];
  };
}
