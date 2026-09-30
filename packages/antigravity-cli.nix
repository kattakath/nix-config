# Google's Antigravity CLI, pinned from the vendor's public release manifest.
#
# The vendor's `curl … | bash` bootstrapper resolves a moving manifest and
# installs a self-updating binary into ~/.local/bin. Pinning the native archive
# makes the executable shared, reviewable, and reproducible like grok.
#
# HOW TO BUMP — the URL embeds a build id (`1.2.13-6662628811079680`) that is
# NOT derivable from the version, so it must be read from the vendor manifest
# rather than guessed:
#
#   curl -fsSL https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/darwin_arm64.json
#   → { "version", "url", "sha512" }
#
# That endpoint comes from DOWNLOAD_BASE_URL in https://antigravity.google/cli/install.sh.
# Unlike grok, Google DOES publish a checksum, so a bump is verifiable at the
# source rather than on trust — always confirm it before pinning:
#
#   shasum -a 512 <tarball>   # must equal the manifest's sha512
#
# Verified for 1.2.13 on 2026-09-29: vendor sha512 matched byte for byte.
#
# The extracted binary is ALSO Developer ID signed, and that survives this
# derivation intact — so a bump gets both checks, same as grok:
#
#   codesign --verify --strict $out/bin/agy   # exit 0
#   Authority=Developer ID Application: Google LLC (EQHXZ8M8AV) → Apple Root CA
#
# Identifier is `cli`, TeamIdentifier `EQHXZ8M8AV`. Unlike grok this file needs
# no `dontFixup` to keep that: the payload is extracted by the installPhase
# rather than treated as an unpackable source, so nixpkgs' Mach-O fixup never
# rewrites it. Do not "tidy" the tar-to-stdout install into a normal unpack.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "1.2.13";
in
stdenvNoCC.mkDerivation {
  pname = "antigravity-cli";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-6662628811079680/darwin-arm/cli_mac_arm64.tar.gz";
    hash = "sha256-CSUT/MITz1A0aAFGqLrSTEBk7OxyOmMPQu59EEbqzJg=";
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    install -d "$out/bin"
    tar -xzf "$src" -O antigravity > "$out/bin/agy"
    chmod 755 "$out/bin/agy"
    runHook postInstall
  '';

  meta = {
    description = "Google Antigravity CLI (vendor-provided prebuilt binary)";
    homepage = "https://antigravity.google/";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "agy";
  };
}
