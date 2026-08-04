# `design-tokens` — transform the gist-hosted DTCG brand tokens (tokens.json) into SCSS / CSS
# / JS via Style Dictionary, so the website / component library / any consumer builds from
# the same single source of truth. A writeShellApplication that fetches tokens.json from the
# baked-in `tokensUrl` (composed from `jsonResumeGistId` in flake.nix — the same gist as
# resume.json + logo.svg) and runs Style Dictionary (v4, via npx) with the bundled config.
#
#   design-tokens [--tokens-url URL] [--out DIR]
#     --tokens-url  raw tokens.json  (default: baked tokensUrl)
#     --out         output dir       (default: ~/.local/share/design-tokens)
#   -> <out>/{scss/_tokens.scss, css/tokens.css, js/tokens.js}
#
# Nix-pinned tools are runtimeInputs (curl, jq, coreutils, nodejs); style-dictionary itself
# is resolved from npm by npx at run time (npm cache thereafter), mirroring how `jsonresume`
# leans on the npm resume CLIs. The shell body lives in ./build.sh.
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
  nodejs,
  lib,
  # Raw tokens.json URL baked at build time (flake.nix tokensUrl, same gist). null → no
  # default; caller must pass --tokens-url.
  tokensUrl ? null,
}:
let
  bakedTokensUrl = if tokensUrl == null then "" else tokensUrl;
in
writeShellApplication {
  name = "design-tokens";
  runtimeInputs = [
    curl
    jq
    coreutils
    nodejs
  ];
  text = ''
    export DT_TOKENS_URL=${lib.escapeShellArg bakedTokensUrl}
    export DT_CONFIG="${
      builtins.path {
        path = ./config.json;
        name = "design-tokens-config.json";
      }
    }"
  ''
  + builtins.readFile ./build.sh;
}
