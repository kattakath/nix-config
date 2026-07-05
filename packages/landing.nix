# packages/landing.nix — the public landing page (the "Civitai collage" live
# wallpaper), assembled as a content-pinned Nix derivation. Served by Caddy
# (modules/nixos/landing.nix) behind a dedicated Cloudflare Tunnel
# (infra/cloudflare/landing.nix):  build → nix build .#landing.
#
# SOURCE OF TRUTH: the page is a single self-contained index.html authored in the
# SEPARATE `civitai` project (not a flake, so it can't be a flake input). Its
# current build is vendored verbatim at ./landing/index.html — re-copy it here
# when it changes (`cp …/civitai/index.html packages/landing/index.html`). The
# committed copy is byte-for-byte upstream; the only transformation is the
# build-time React rewrite below, so the repo file stays pristine/diffable.
#
# REPRODUCIBILITY / third-party surface:
#   • React + ReactDOM are pinned to IMMUTABLE unpkg version URLs and inlined into
#     vendor/ at build time; substituteInPlace rewrites the two <script src> to
#     the local copies, so the core runtime makes no third-party request.
#   • The WebGPU shader lib (esm.sh) is loaded LAZILY, only when a visual filter
#     is active, and is deliberately NOT vendored: esm.sh serves via opaque,
#     rebuild-versioned bundle URLs (a re-export stub → hashed path) that cannot
#     be fetched reproducibly. It — and Google Fonts — are instead constrained by
#     the Caddy Content-Security-Policy in modules/nixos/landing.nix.
{
  runCommandLocal,
  fetchurl,
}:
let
  # Immutable, content-addressed by hash. Bump the version AND the hash together.
  react = fetchurl {
    url = "https://unpkg.com/react@18.3.1/umd/react.production.min.js";
    hash = "sha256-2Unxw2h67a3O2shSYYZfKbF80nOZfn9rK/xTsvnUxN0=";
  };
  reactDom = fetchurl {
    url = "https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js";
    hash = "sha256-NfT5dPSyvNRNpzljNH+JUuNB+DkJ5EmCJ9Tia5j2bw0=";
  };
in
runCommandLocal "landing" { } ''
  mkdir -p "$out/vendor"
  cp ${react} "$out/vendor/react.js"
  cp ${reactDom} "$out/vendor/react-dom.js"
  cp ${./landing/index.html} "$out/index.html"

  # Rewrite ONLY the two React CDN <script src> to the vendored local copies.
  # --replace-fail turns any upstream drift (URL no longer present) into a build
  # error rather than a silent CDN fallback. The esm.sh import + Google Fonts are
  # intentionally left untouched (CSP-governed; see the module).
  substituteInPlace "$out/index.html" \
    --replace-fail 'https://unpkg.com/react@18/umd/react.production.min.js' 'vendor/react.js' \
    --replace-fail 'https://unpkg.com/react-dom@18/umd/react-dom.production.min.js' 'vendor/react-dom.js'
''
