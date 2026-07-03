#!/usr/bin/env bash
# garnix-log.sh — fetch a Garnix CI build log headlessly via curl.
#
# Usage: garnix-log.sh <BUILD_ID|BUILD_URL> [raw|json]   (default: raw)
#
# Reads the session JWT from the env var GARNIX_JWT_COOKIE. The token is NEVER
# printed, echoed, or written anywhere — only sent as a cookie to app.garnix.io.
#
# Endpoints:
#   raw  → https://app.garnix.io/api/build/<ID>/logs/raw  (clean plaintext)
#   json → https://app.garnix.io/api/build/<ID>/logs      ({"finished":…,"logs":[…]})
set -euo pipefail

fallback_guidance() {
  # $1 = reason ("missing" | "expired")
  local reason="${1:-missing}"
  {
    echo "garnix-log: cannot fetch — GARNIX_JWT_COOKIE is ${reason}."
    echo
    echo "Provide the Garnix session JWT in-session (it is NOT stored anywhere):"
    echo
    echo "    ! export GARNIX_JWT_COOKIE='<paste JWT-Cookie value here>'"
    echo
    echo "How to obtain it: from a logged-in app.garnix.io session, copy the value"
    echo "of the 'JWT-Cookie' cookie — browser DevTools → Application/Storage →"
    echo "Cookies, or the Cookie header of any /api/build/*/logs request."
    echo
    echo "The JWT expires; re-export it when fetches start failing."
  } >&2
}

usage() {
  echo "Usage: garnix-log.sh <BUILD_ID|BUILD_URL> [raw|json]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage

arg="$1"
fmt="${2:-raw}"

case "$fmt" in
  raw | json) ;;
  *)
    echo "garnix-log: format must be 'raw' or 'json' (got '$fmt')" >&2
    exit 2
    ;;
esac

# Accept a full build URL and extract the ID, or take the ID directly.
if printf '%s' "$arg" | grep -q '/build/'; then
  build_id="${arg##*/build/}"
  build_id="${build_id%%[/?#]*}"
else
  build_id="$arg"
fi

if [ -z "$build_id" ]; then
  echo "garnix-log: could not determine a build ID from '$arg'" >&2
  exit 2
fi

# Env-var gate: never call curl without a token.
if [ -z "${GARNIX_JWT_COOKIE:-}" ]; then
  fallback_guidance missing
  exit 3
fi

base="https://app.garnix.io"
if [ "$fmt" = "raw" ]; then
  url="$base/api/build/$build_id/logs/raw"
else
  url="$base/api/build/$build_id/logs"
fi

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

# -sS: silent but show errors; -w: append HTTP status after the body.
http_code="$(
  curl -sS -o "$body_file" -w '%{http_code}' \
    -b "NO-XSRF-TOKEN=; JWT-Cookie=${GARNIX_JWT_COOKIE}" \
    -H 'accept: */*' \
    -H "referer: $base/build/$build_id" \
    -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36' \
    "$url" 2>/dev/null || true
)"

# Detect auth failure: non-200, empty body, or an HTML page (login/redirect)
# served instead of the log. Match ONLY structural HTML markers at the start of
# the body — NOT loose words like "login"/"sign in", which legitimately appear
# in build logs (e.g. `cloudflared tunnel login`) and would false-positive.
if [ "$http_code" != "200" ] \
  || [ ! -s "$body_file" ] \
  || head -c 512 "$body_file" | grep -qiE '<!doctype html|<html[ >]'; then
  echo "garnix-log: request for build '$build_id' failed (HTTP ${http_code:-none}); the token likely expired." >&2
  fallback_guidance expired
  exit 4
fi

if [ "$fmt" = "raw" ]; then
  # Strip embedded ANSI color codes for clean output/grepping.
  sed $'s/\x1b\\[[0-9;]*m//g' "$body_file"
else
  if command -v jq >/dev/null 2>&1; then
    jq . "$body_file"
  else
    cat "$body_file"
  fi
fi
