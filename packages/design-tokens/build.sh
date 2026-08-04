# design-tokens — transform the gist-hosted DTCG tokens.json into SCSS / CSS / JS via
# Style Dictionary.
#
# Concatenated after the writeShellApplication preamble (shebang, set -euo pipefail, PATH
# from runtimeInputs, exported DT_*). Plain bash — no shebang / set here.
#
# Config (exported by the Nix wrapper):
#   DT_TOKENS_URL  raw tokens.json URL baked from tokensUrl ("" if unset)
#   DT_CONFIG      store path of the bundled Style Dictionary config.json
# Overrides: --tokens-url URL, --out DIR   (default out: ~/.local/share/design-tokens)

tokens_url="${DT_TOKENS_URL:-}"
config="${DT_CONFIG:?DT_CONFIG not set}"
out_dir="$HOME/.local/share/design-tokens"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tokens-url) tokens_url="${2:?--tokens-url needs a value}"; shift 2 ;;
    --out) out_dir="${2:?--out needs a value}"; shift 2 ;;
    -h | --help)
      printf 'usage: design-tokens [--tokens-url URL] [--out DIR]\n'
      printf '  Fetches the DTCG tokens.json (default baked from the gist) and runs Style\n'
      printf '  Dictionary to emit <out>/{scss/_tokens.scss, css/tokens.css, js/tokens.js}.\n'
      exit 0
      ;;
    *) printf 'design-tokens: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$tokens_url" ]; then
  printf 'design-tokens: no tokens URL (pass --tokens-url, or bake tokensUrl)\n' >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/design-tokens.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if ! curl -fsSL "$tokens_url" -o "$work/tokens.json"; then
  printf 'design-tokens: could not fetch tokens from %s\n' "$tokens_url" >&2
  exit 1
fi
if ! jq -e . "$work/tokens.json" >/dev/null 2>&1; then
  printf 'design-tokens: fetched tokens is not valid JSON\n' >&2
  exit 1
fi
cp "$config" "$work/config.json"

# Run Style Dictionary (v4) from npm via npx into $work/build/{scss,css,js}. Network step:
# npx resolves style-dictionary on first use (npm cache thereafter).
( cd "$work" && npx --yes style-dictionary@^4 build --config config.json )

mkdir -p "$out_dir"
cp -R "$work/build/." "$out_dir/"
printf 'design-tokens: wrote %s/{scss,css,js}\n' "$out_dir"
