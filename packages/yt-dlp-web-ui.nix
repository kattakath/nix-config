# yt-dlp-web-ui v4, built from source.
#
# The upstream flake cannot be used here. Its `systems` list is x86_64-linux
# only, so it exports nothing for aarch64-darwin or aarch64-linux. The Nix in
# that repo still calls `buildGo123Module` and passes `-host`/`-port`, which
# v4 removed (`main.go` accepts only `-conf`). The published release binaries
# are Linux ELF only. Docker Hub's `:v4` tag does not exist; `latest` is a
# June 2026 image whose yt-dlp is too old to pass YouTube without a JS runtime
# the image does not ship.
#
# v4 embeds the UI: `//go:embed frontend/dist/...` in main.go. The frontend is
# built first and copied into the tree before `go build`.
{
  lib,
  fetchFromGitHub,
  buildGoModule,
  stdenv,
  nodejs,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
}:
let
  version = "4.0.0";

  src = fetchFromGitHub {
    owner = "marcopiovanello";
    repo = "yt-dlp-web-ui";
    tag = "v${version}";
    hash = "sha256-nUjPpVznJnDjmnlU5mkvTUcQjYhpaNw827RqRrdgKkg=";
  };

  frontend = stdenv.mkDerivation {
    pname = "yt-dlp-web-ui-frontend";
    inherit version src;

    sourceRoot = "${src.name}/frontend";

    nativeBuildInputs = [
      nodejs
      pnpm_10
      pnpmConfigHook
    ];

    pnpmDeps = fetchPnpmDeps {
      pname = "yt-dlp-web-ui-frontend";
      inherit version src;
      sourceRoot = "${src.name}/frontend";
      pnpm = pnpm_10;
      # lockfileVersion 9.0. pnpm 9 still accepts fetcherVersion 3; pnpm 11 does not.
      fetcherVersion = 3;
      hash = "sha256-92PFDyYqREiRr4GqAZrJQ6qlDLh5IchhaZevTlenhQI=";
    };

    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R dist/. "$out/"
      runHook postInstall
    '';
  };
in
buildGoModule {
  pname = "yt-dlp-web-ui";
  inherit version src;

  vendorHash = "sha256-tRL3WGUAVv+i/eAvMybP0sbAu/cFK6xHYrcImqntyOU=";

  # The embed paths are frontend/dist/index.html and frontend/dist/assets/*.
  preBuild = ''
    rm -rf frontend/dist
    mkdir -p frontend/dist
    cp -R ${frontend}/. frontend/dist/
  '';

  meta = {
    description = "Web UI and HTTP API in front of yt-dlp";
    homepage = "https://github.com/marcopiovanello/yt-dlp-web-ui";
    license = lib.licenses.gpl3Only;
    mainProgram = "yt-dlp-web-ui";
  };
}
