# `email-signature` — generate a self-contained HTML email signature from a JSON Resume
# (jsonresume.org) plus a logo SVG, BOTH fetched from the same gist (one source of truth).
# A thin writeShellApplication mirroring packages/jsonresume.nix: resume.json is fetched with
# `curl` from the baked-in `defaultUrl` and logo.svg from `logoUrl` (both composed from
# `jsonResumeGistId` in flake.nix); the logo is cached locally, rasterized to PNG with
# `rsvg-convert` (librsvg), and embedded as a base64 data URI — one paste-ready
# `signature.html`.
#
#   email-signature [--url URL] [--logo-url URL] [--tokens-url URL] [--out DIR]
#     --url         raw resume.json  (default: baked jsonResumeUrl)
#     --logo-url    raw logo.svg     (default: baked logoUrl)
#     --tokens-url  raw tokens.json  (default: baked tokensUrl; colours + font family)
#     --out         output dir       (default: ~/.local/share/email-signature)
#
# All Nix-pinned tools are `runtimeInputs` (curl, jq, coreutils, librsvg); nothing is
# expected on the caller's PATH. The shell body lives in ./signature.sh (plain bash,
# concatenated after the wrapper preamble that exports the EMAIL_SIG_* config).
{
  writeShellApplication,
  curl,
  jq,
  coreutils,
  librsvg,
  lib,
  # Raw resume.json URL baked at build time (flake.nix jsonResumeUrl). null → no default,
  # caller must pass --url.
  defaultUrl ? null,
  # Raw logo.svg URL baked at build time (flake.nix logoUrl, same gist). null → no default;
  # the generator then relies on a previously cached logo (or skips, best-effort).
  logoUrl ? null,
  # Raw tokens.json (DTCG brand tokens) URL baked at build time (flake.nix tokensUrl, same
  # gist). null → no default; the generator then uses built-in colour/font fallbacks.
  tokensUrl ? null,
}:
let
  bakedUrl = if defaultUrl == null then "" else defaultUrl;
  bakedLogoUrl = if logoUrl == null then "" else logoUrl;
  bakedTokensUrl = if tokensUrl == null then "" else tokensUrl;
in
writeShellApplication {
  name = "email-signature";
  runtimeInputs = [
    curl
    jq
    coreutils
    librsvg
  ];
  # SC2016: the jq filters intentionally contain `["$value"]` (DTCG key syntax) inside single
  # quotes — that `$value` is jq, not a shell variable, so the "expressions don't expand in
  # single quotes" warning is a false positive here.
  excludeShellChecks = [ "SC2016" ];
  text = ''
    export EMAIL_SIG_DEFAULT_URL=${lib.escapeShellArg bakedUrl}
    export EMAIL_SIG_LOGO_URL=${lib.escapeShellArg bakedLogoUrl}
    export EMAIL_SIG_TOKENS_URL=${lib.escapeShellArg bakedTokensUrl}
  ''
  + builtins.readFile ./signature.sh;
}
