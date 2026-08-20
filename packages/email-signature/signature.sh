# email-signature — generate an HTML email signature from a JSON Resume, a gist-hosted logo,
# and gist-hosted brand tokens.
#
# This file is concatenated after the writeShellApplication preamble (which sets the
# shebang, `set -euo pipefail`, PATH from runtimeInputs, and exports EMAIL_SIG_*). It is
# plain bash — do NOT add a shebang or `set` here.
#
# Config (exported by the Nix wrapper):
#   EMAIL_SIG_DEFAULT_URL  raw resume.json URL baked from jsonResumeUrl ("" if unset)
#   EMAIL_SIG_LOGO_URL     raw logo.svg URL baked from logoUrl, SAME gist ("" if unset)
#   EMAIL_SIG_TOKENS_URL   raw tokens.json (DTCG) URL baked from tokensUrl, SAME gist ("")
# Overrides: --url URL, --logo-url URL, --tokens-url URL, --out DIR
#            (default out: ~/.local/share/email-signature)
#
# Single source of truth: resume.json, logo.svg AND tokens.json all come from the gist.
# resume + logo are required; tokens are OPTIONAL (colours + font fall back to defaults).
# Each is cached under <out>/ so a later offline run still renders.

default_url="${EMAIL_SIG_DEFAULT_URL:-}"
default_logo_url="${EMAIL_SIG_LOGO_URL:-}"
default_tokens_url="${EMAIL_SIG_TOKENS_URL:-}"

out_dir="$HOME/.local/share/email-signature"
url="$default_url"
logo_url="$default_logo_url"
tokens_url="$default_tokens_url"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --url) url="${2:?--url needs a value}"; shift 2 ;;
    --logo-url) logo_url="${2:?--logo-url needs a value}"; shift 2 ;;
    --tokens-url) tokens_url="${2:?--tokens-url needs a value}"; shift 2 ;;
    --out) out_dir="${2:?--out needs a value}"; shift 2 ;;
    -h | --help)
      printf 'usage: email-signature [--url URL] [--logo-url URL] [--tokens-url URL] [--out DIR]\n'
      printf '  Renders <out>/signature.html from the JSON Resume at URL, the logo.svg at\n'
      printf '  LOGO-URL, and brand colours/font from the DTCG tokens.json at TOKENS-URL\n'
      printf '  (defaults baked from the gist). Each is cached under <out>/ for offline use.\n'
      exit 0
      ;;
    *) printf 'email-signature: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -z "$url" ]; then
  printf 'email-signature: no resume URL (pass --url, or bake defaultUrl)\n' >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/email-signature.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$out_dir"

# Fetch + validate the resume. Network step: the activation wrapper runs us with `|| true`,
# and we never overwrite an existing artifact unless the fetch + render fully succeed.
if ! curl -fsSL "$url" -o "$work/resume.json"; then
  printf 'email-signature: could not fetch resume from %s (keeping existing artifact)\n' "$url" >&2
  exit 1
fi
if ! jq -e . "$work/resume.json" >/dev/null 2>&1; then
  printf 'email-signature: fetched resume is not valid JSON\n' >&2
  exit 1
fi

# Obtain the logo: fetch from the gist (validating it parses as SVG via a tiny rsvg render)
# and refresh the local cache; on failure fall back to the cached copy; if neither exists,
# skip (best-effort — keep any existing artifact).
cached_logo="$out_dir/logo.svg"
logo_src=""
if [ -n "$logo_url" ] \
  && curl -fsSL "$logo_url" -o "$work/logo.svg" \
  && rsvg-convert -w 8 "$work/logo.svg" -o "$work/logo_probe.png" 2>/dev/null; then
  cp -f "$work/logo.svg" "$cached_logo"
  logo_src="$work/logo.svg"
elif [ -f "$cached_logo" ]; then
  printf 'email-signature: logo fetch failed; using cached %s\n' "$cached_logo" >&2
  logo_src="$cached_logo"
else
  printf 'email-signature: no logo available (fetch failed, no cache) — keeping existing artifact\n' >&2
  exit 1
fi

# Brand tokens (DTCG): fetch from the same gist and cache. OPTIONAL + non-fatal — any missing
# value falls back to the built-in default below, so the signature always renders.
cached_tokens="$out_dir/tokens.json"
tokens_file=""
if [ -n "$tokens_url" ] \
  && curl -fsSL "$tokens_url" -o "$work/tokens.json" \
  && jq -e . "$work/tokens.json" >/dev/null 2>&1; then
  cp -f "$work/tokens.json" "$cached_tokens"
  tokens_file="$work/tokens.json"
elif [ -f "$cached_tokens" ]; then
  tokens_file="$cached_tokens"
fi

# tok <jq-filter> <default> — read a token value, falling back to <default> when tokens are
# absent or the value is missing/empty.
tok() {
  if [ -n "$tokens_file" ]; then
    local v
    v="$(jq -r "$1" "$tokens_file" 2>/dev/null || printf '')"
    if [ -n "$v" ] && [ "$v" != "null" ]; then
      printf '%s' "$v"
      return
    fi
  fi
  printf '%s' "$2"
}

ink="$(tok '.color.ink["$value"] // empty' '#000000')"
surface="$(tok '.color.surface["$value"] // empty' '#ffffff')"
# Offline fallbacks track the Duochrome system: links are ink (#000000), not coloured, and
# the family is Roboto-first (Helvetica before Arial). These apply only when tokens are
# unreachable — normally the values come straight from tokens.json.
link="$(tok '.color.link["$value"] // empty' '#000000')"
font_family="$(tok '((.font.family.body["$value"]) // []) | join(", ") | select(length > 0)' 'Roboto, Helvetica, Arial, sans-serif')"

# --- pull fields from resume.json (source of truth) -------------------------
name="$(jq -r '.basics.name // ""' "$work/resume.json")"
label="$(jq -r '.basics.label // ""' "$work/resume.json")"
website="$(jq -r '.basics.url // ""' "$work/resume.json")"
linkedin="$(jq -r '[.basics.profiles[]? | select(((.network // "") | ascii_downcase) == "linkedin") | .url] | first // ""' "$work/resume.json")"
github="$(jq -r '[.basics.profiles[]? | select(((.network // "") | ascii_downcase) == "github") | .url] | first // ""' "$work/resume.json")"

# basics.label -> "Title | Subtitle"
title="$(printf '%s' "$label" | cut -d'|' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
subtitle=""
case "$label" in
  *"|"*) subtitle="$(printf '%s' "$label" | cut -d'|' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" ;;
esac

# Blocked-logo fallback: the all-caps name, rendered bold via the img's inline style.
alt="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"

html_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
title="$(html_escape "$title")"
subtitle="$(html_escape "$subtitle")"
alt="$(html_escape "$alt")"
linkedin="$(html_escape "$linkedin")"
github="$(html_escape "$github")"
website="$(html_escape "$website")"
# $name itself only ever lands in the <title> below (the visible body uses the
# already-escaped $alt derived from it) — escape it too for the same defense-
# in-depth reason as the fields above.
name_escaped="$(html_escape "$name")"

# Rasterize the (tight-cropped) SVG to PNG and embed it as a base64 data URI so the
# signature is a single self-contained file to paste into Gmail settings.
rsvg-convert -w 240 "$logo_src" -o "$work/logo.png"
logo_uri="data:image/png;base64,$(base64 -w0 "$work/logo.png")"

# Colours + font come from brand tokens ($ink/$surface/$link/$font_family). Font is Roboto-
# first with web-safe fallbacks (Gmail renders Roboto; other clients fall back). Sizes map to
# Gmail's menu: title = "Large"; subtitle + links = "Normal" (~13px). Links stay the link colour.
cat > "$work/signature.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>Email signature — $name_escaped</title></head>
<body style="margin:24px;background:$surface;">
<table cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-family:$font_family;color:$ink;">
  <tr>
    <td style="vertical-align:middle;padding:0 18px 0 0;">
      <img src="$logo_uri" width="120" height="47" alt="$alt" style="display:block;border:0;font-family:$font_family;font-size:18px;font-weight:bold;color:$ink;">
    </td>
    <td style="vertical-align:middle;border-left:2px solid $ink;padding:0 0 0 18px;line-height:normal;">
      <div style="font-size:large;font-weight:bold;color:$ink;">$title</div>
      <div style="font-size:13px;color:$ink;padding-top:2px;">$subtitle</div>
      <div style="font-size:13px;padding-top:6px;color:$ink;">
        <a href="$linkedin" style="color:$link;text-decoration:underline;">LinkedIn</a> &nbsp;&bull;&nbsp; <a href="$github" style="color:$link;text-decoration:underline;">GitHub</a> &nbsp;&bull;&nbsp; <a href="$website" style="color:$link;text-decoration:underline;">Website</a>
      </div>
    </td>
  </tr>
</table>
</body></html>
HTML

mv -f "$work/signature.html" "$out_dir/signature.html"
printf 'email-signature: wrote %s/signature.html\n' "$out_dir"
