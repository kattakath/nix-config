# Google's Antigravity CLI, pinned from the vendor's public release manifest.
#
# The vendor's `curl … | bash` bootstrapper resolves a moving manifest and
# installs a self-updating binary into ~/.local/bin. Pinning the native archive
# makes the executable shared, reviewable, and reproducible like grok.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  version = "1.2.4";
in
stdenvNoCC.mkDerivation {
  pname = "antigravity-cli";
  inherit version;

  src = fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.4-6085322963025920/darwin-arm/cli_mac_arm64.tar.gz";
    hash = "sha256-9ZwSwonnS7tIF4+CdwLGIkvQqpIJFDGfhbQnYN/HL0w=";
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
