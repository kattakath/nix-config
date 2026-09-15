#!/usr/bin/env bash
# Refresh the fallback wallpaper image, at most once per NRT_ART_TTL_HOURS.
#
# Runs UNAUTHENTICATED on purpose. The browse endpoint returns HTTP 200 with no
# key (measured), and a launchd agent reaching into the login Keychain adds a
# failure mode — locked keychain, no access — for zero benefit. `civitai.com:api`
# is in the Keychain if rate limits ever bite; wire it with `secret exec` then.
#
# RATING: the ceiling is the operator's setting (default None), enforced twice —
# server-side via the `nsfw` query param and again client-side on each item's
# `browsingLevel`, because trusting one server field alone is a single point of
# failure. The audience gate below is the only thing that overrides the setting.
set -euo pipefail

ART_FILE="${NRT_ART_FILE:?NRT_ART_FILE required}"
TTL_HOURS="${NRT_ART_TTL_HOURS:-6}"
# Endpoint is operator-configurable (`local.nextRightThing.artSource`); Civitai
# is only the default. Must return JSON with items[].url and items[].browsingLevel.
# \$RATING stays LITERAL here — it is a placeholder substituted further down,
# not a variable to expand now (RATING is not set yet, and set -u would abort).
API_TEMPLATE="${NRT_ART_SOURCE:-https://civitai.red/api/v1/images?limit=40&nsfw=\$RATING&sort=Most%20Reactions&period=Week}"

# Operator's call, not a hardcoded policy. Civitai's own rating ladder:
#   None (PG) | Soft (PG-13) | Mature (R) | X
# Default None. Set `local.nextRightThing.artRating` to change it.
RATING="${NRT_NSFW:-None}"

# AUDIENCE GATE — the one place the setting is overridden, and it exists because
# this is a WALLPAPER behind every window, not a private viewer. If the screen is
# likely being shown to other people, drop to None regardless of the setting.
# Same downgrade principle the text side uses for private items.
if [ "${NRT_AUDIENCE_GATE:-1}" = "1" ] && pgrep -qx \
     -f 'zoom.us|Microsoft Teams|Webex|OBS|ScreenSharing|Slack Call' 2>/dev/null; then
  RATING="None"
fi

# Client-side ceiling per rating, asserted independently of the server's filter.
case "$RATING" in
  None)   MAXLEVEL=1 ;;
  Soft)   MAXLEVEL=2 ;;
  Mature) MAXLEVEL=4 ;;
  X)      MAXLEVEL=99 ;;
  *)      RATING="None"; MAXLEVEL=1 ;;
esac

mkdir -p "$(dirname "$ART_FILE")"

# Still fresh? Leave it. Keeps the widget working with the network down.
if [ -s "$ART_FILE" ] && [ -n "$(find "$ART_FILE" -mmin "-$((TTL_HOURS * 60))" 2>/dev/null)" ]; then
  exit 0
fi

# Explicit XXXXXX template: GNU coreutils shadows BSD mktemp on this Mac and
# GNU rejects `-t name` outright ("too few X's").
tmp="$(mktemp "${TMPDIR:-/tmp}/nrt-art.XXXXXX")"
trap 'rm -f "$tmp" "$tmp.json" "$tmp.jpg"' EXIT

# Plain string substitution, never eval: the template is config, but expanding
# it through the shell would let any character in it run as code.
API_URL="${API_TEMPLATE//\$RATING/$RATING}"

# Optional bearer auth. Some listing endpoints return a different (and much
# larger) corpus only when authenticated, and a key also lifts rate limits.
# The VALUE is read from the environment and never echoed, logged or written —
# the keychain-secrets loader exports it; this script only forwards it.
AUTH=()
if [ -n "${NRT_ART_TOKEN:-}" ]; then
  AUTH=(-H "Authorization: Bearer $NRT_ART_TOKEN")
fi

curl -fsSL -m 25 --retry 2 --retry-delay 3 "${AUTH[@]}" "$API_URL" -o "$tmp.json" 2>/dev/null || exit 0

# Independent client-side gate. `nsfwLevel` must be the literal "None" AND
# `browsingLevel` must be 1 — trusting either alone trusts one server field.
url="$(jq -r --argjson max "$MAXLEVEL" '
  [ .items[]
    | select((.browsingLevel // 99) <= $max)
    | select(.url != null and (.url | test("^https://")))
    | .url
  ] | if length == 0 then empty else .[0] end
' "$tmp.json" 2>/dev/null || true)"

[ -z "$url" ] && exit 0

# -L is REQUIRED: image.civitai.com answers 301 and, without it, curl writes a
# zero-byte body and still exits 0 — a silent empty wallpaper (measured).
# Send the token ONLY if the image lives on the same host as the API. The
# listing host and the image CDN differ (civitai.red vs image.civitai.com), and
# attaching the credential to a third-party host hands it to whoever runs that
# CDN — including through -L redirects. Same host: keep it, some corpora gate
# the file too. Different host: drop it.
api_host="${API_URL#*://}"; api_host="${api_host%%/*}"
img_host="${url#*://}";     img_host="${img_host%%/*}"
IMG_AUTH=()
[ "$api_host" = "$img_host" ] && IMG_AUTH=("${AUTH[@]}")

curl -fsSL -m 45 "${IMG_AUTH[@]+"${IMG_AUTH[@]}"}" "$url" -o "$tmp" 2>/dev/null || exit 0
[ -s "$tmp" ] || exit 0

# Must actually be an image; a truncated download or an error page would
# otherwise be base64'd straight onto the desktop.
case "$(file -b --mime-type "$tmp")" in
  image/*) : ;;
  *) exit 0 ;;
esac

# Normalise to a screen-sized JPEG. Two reasons, both measured: the URL says
# .jpeg but the bytes came back image/png, so the extension cannot be trusted to
# pick a data: MIME; and the original was 2.5 MB, which srcDoc pays RAW (no
# gzip) and inflates ~33% more as base64. sips ships with macOS — no new dep.
# 1920 wide at q60: this is a BACKDROP seen for about a second during a space
# switch, behind windows — it does not need retina fidelity, and every byte is
# paid raw by srcDoc and then inflated ~33% by base64. 2560/default-quality
# measured 1.0 MB -> a 1.5 MB HTML file, which is too heavy to re-read on a timer.
if ! sips -Z 1920 -s format jpeg -s formatOptions 60 "$tmp" --out "$tmp.jpg" >/dev/null 2>&1; then
  exit 0
fi
[ -s "$tmp.jpg" ] || exit 0
mv -f "$tmp.jpg" "$ART_FILE"
