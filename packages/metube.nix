# MeTube, built from source. nixpkgs has no package for it.
#
# The UI is an Angular app whose output must land at ui/dist/metube/browser,
# which is the path app/main.py serves. Python deps come from nixpkgs rather
# than `uv sync`: the app is a handful of imports, and the lockfile would pull
# a second yt-dlp. deno, ffmpeg and aria2 are on PATH because yt-dlp looks
# them up by name. YouTube extraction fails without deno.
{
  lib,
  fetchFromGitHub,
  stdenv,
  nodejs,
  pnpm_11,
  fetchPnpmDeps,
  pnpmConfigHook,
  python3,
  makeWrapper,
  ffmpeg,
  deno,
  aria2,
}:
let
  version = "2026.09.20";

  src = fetchFromGitHub {
    owner = "alexta69";
    repo = "metube";
    tag = version;
    hash = "sha256-bZDEHSqP6AY59u+5hy0gAPy5mhv77l1Dl7jQRckE7kY=";
  };

  frontend = stdenv.mkDerivation {
    pname = "metube-ui";
    inherit version src;

    sourceRoot = "${src.name}/ui";

    nativeBuildInputs = [
      nodejs
      pnpm_11
      pnpmConfigHook
    ];

    pnpmDeps = fetchPnpmDeps {
      pname = "metube-ui";
      inherit version src;
      sourceRoot = "${src.name}/ui";
      pnpm = pnpm_11;
      # ui/package.json pins pnpm 11. fetcherVersion 3 is rejected for pnpm 11.
      fetcherVersion = 4;
      hash = "sha256-BiaQd020GbBqhIkUl5WWL4P5m5KaiV6L/of04s1Zs4g=";
    };

    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R dist/metube/. "$out/"
      runHook postInstall
    '';
  };

  pythonEnv = python3.withPackages (
    ps: with ps; [
      aiohttp
      python-socketio
      yt-dlp
      mutagen
      curl-cffi
      watchfiles
    ]
  );
in
stdenv.mkDerivation {
  pname = "metube";
  inherit version src;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/metube/ui/dist"
    cp -R app "$out/lib/metube/app"
    cp -R ${frontend} "$out/lib/metube/ui/dist/metube"
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/metube" \
      --chdir "$out/lib/metube" \
      --prefix PATH : ${
        lib.escapeShellArg (
          lib.makeBinPath [
            ffmpeg
            deno
            aria2
          ]
        )
      } \
      --add-flags app/main.py
    runHook postInstall
  '';

  meta = {
    description = "Web UI for yt-dlp, with a queue";
    homepage = "https://github.com/alexta69/metube";
    license = lib.licenses.agpl3Plus;
    mainProgram = "metube";
  };
}
