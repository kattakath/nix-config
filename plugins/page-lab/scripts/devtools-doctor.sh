#!/usr/bin/env bash
# devtools-doctor.sh — connection preflight for chrome-devtools-mcp.
#
# WHY THIS EXISTS. Almost every "the DevTools tools are broken" report is really one
# of three different things, and they need three different fixes:
#
#   1. no Node / no npx           -> the server cannot start at all
#   2. nothing listening on the   -> the browser was not launched with
#      debugging port                --remote-debugging-port (it is a STARTUP flag;
#                                     a running browser cannot be switched into it)
#   3. something IS listening,    -> upstream officially supports Google Chrome and
#      but it is a browser           Chrome for Testing only; other Chromium builds
#      upstream does not support     "may work, but this is not guaranteed"
#
# Guessing between those costs turns. This answers it in one command.
#
#   usage: devtools-doctor.sh [browser-url]        (default http://127.0.0.1:9222)
#          devtools-doctor.sh --verify-tools       tool-count drift check (needs network)
#
# Exit 0 when a debugging endpoint answered, 1 otherwise. Launch mode (the server
# starting its own Chrome) needs no endpoint, so a failure here is only meaningful
# when attaching.

set -uo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TOOLS_MD="$SCRIPT_DIR/../skills/page-diagnose/references/tools.md"

verify_tools=0
URL="http://127.0.0.1:9222"
for arg in "$@"; do
  case "$arg" in
    --verify-tools) verify_tools=1 ;;
    -h | --help)
      printf 'usage: devtools-doctor.sh [browser-url] | devtools-doctor.sh --verify-tools\n' >&2
      exit 2
      ;;
    *) URL="$arg" ;;
  esac
done
rc=0

# --verify-tools — is the catalogue still describing the server we actually run?
#
# WHY. Upstream's generated tool reference is written from main and describes roughly twice
# what the pinned release ships, so "the docs say this tool exists" is not evidence
# [F-CDP-29TOOLS]. tools.md therefore carries the count MEASURED against the pinned version,
# and this flag re-measures it. A drift is a warning (exit 3), not a failure: the fix is to
# re-measure and re-date the catalogue, not to block the operator's actual task.
#
# It fetches the server over the network, so it must NEVER run inside the Nix check.
if [ "$verify_tools" = 1 ]; then
  [ -r "$TOOLS_MD" ] || {
    printf 'cannot read %s — the measurement header lives there\n' "$TOOLS_MD" >&2
    exit 1
  }
  want_ver=$(sed -n 's/^MEASURED_VERSION=\(.*\)$/\1/p' "$TOOLS_MD" | head -1)
  want_count=$(sed -n 's/^MEASURED_TOOL_COUNT=\([0-9]*\)$/\1/p' "$TOOLS_MD" | head -1)
  want_pkg=$(sed -n 's/^MEASURED_PACKAGE=\(.*\)$/\1/p' "$TOOLS_MD" | head -1)
  want_pkg="${want_pkg:-chrome-devtools-mcp}"
  if [ -z "$want_ver" ] || [ -z "$want_count" ]; then
    printf 'no page-lab:tools-measurement header in %s — nothing to compare against\n' "$TOOLS_MD" >&2
    exit 1
  fi
  command -v npx >/dev/null 2>&1 || {
    printf 'npx not on PATH — cannot start the pinned server\n' >&2
    exit 1
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'jq not on PATH — cannot count the tools/list response\n' >&2
    exit 1
  }

  runner=(npx -y "$want_pkg@$want_ver" --no-usage-statistics --no-performance-crux)
  command -v timeout >/dev/null 2>&1 && runner=(timeout 120 "${runner[@]}")

  # Both privacy flags on EVERY invocation: --no-performance-crux is the data-egress one,
  # and without it the traced URLs go to Google's CrUX API.
  got_count=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"page-lab-doctor","version":"0"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' |
    "${runner[@]}" 2>/dev/null |
    jq -r 'select(.id==2) | .result.tools | length' 2>/dev/null | head -1)

  if [ -z "$got_count" ]; then
    printf 'the server returned no tools/list — cannot verify (network? npx cache?)\n' >&2
    exit 1
  fi

  printf 'TOOLS_VERSION=%s TOOLS_COUNT=%s TOOLS_DRIFT=%s\n' \
    "$want_ver" "$got_count" "$([ "$got_count" = "$want_count" ] && printf 'no' || printf 'yes')"
  [ "$got_count" = "$want_count" ] && exit 0
  printf 'catalogue says %s tools, the pinned server answered %s — re-measure and re-date %s\n' \
    "$want_count" "$got_count" "$TOOLS_MD" >&2
  exit 3
fi

say() { printf '%s\n' "$1"; }
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1" >&2
  rc=1
}
note() { printf '  note  %s\n' "$1"; }

say "chrome-devtools-mcp doctor"
say ""

say "runtime"
if command -v node >/dev/null 2>&1; then
  ok "node $(node --version)"
else
  bad "node not on PATH — the MCP server cannot start"
fi
if command -v npx >/dev/null 2>&1; then
  ok "npx present"
else
  bad "npx not on PATH"
fi

say ""
say "debugging endpoint ($URL)"

if ! command -v curl >/dev/null 2>&1; then
  note "curl not on PATH — skipping the endpoint probe"
  exit "$rc"
fi

# /json/version is the CDP discovery endpoint. A JSON body naming the build means a
# browser is genuinely listening; anything else means it is not.
body=$(curl -fsS --max-time 5 "$URL/json/version" 2>/dev/null || true)

if [ -z "$body" ]; then
  bad "no response — nothing is listening"
  say ""
  say "  A browser only listens if it was STARTED with the flag. Quit it fully, then:"
  say "    open -na \"Chromium\"      --args --remote-debugging-port=9222"
  say "    open -na \"Google Chrome\" --args --remote-debugging-port=9222"
  say ""
  say "  Relaunching while the same profile is still running silently reuses the"
  say "  existing process and the port never opens — which looks like the flag being"
  say "  ignored. Check with: pgrep -fl 'Chromium|Google Chrome'"
  say ""
  say "  Not attaching? Then this is fine: in launch mode the server starts its own"
  say "  browser and needs no endpoint."
  exit 1
fi

ok "endpoint answered"

browser=$(printf '%s' "$body" | sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
proto=$(printf '%s' "$body" | sed -n 's/.*"Protocol-Version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -n "$browser" ] && ok "browser: $browser"
[ -n "$proto" ] && ok "CDP protocol: $proto"

# The build string does NOT identify the vendor. Measured 2026-09-06:
# ungoogled-chromium reports  "Browser": "Chrome/152.0.7977.64"  — identical in
# shape to Google Chrome, and /json/version carries no vendor field. So the only
# honest discriminator is which application is actually serving the port.
app=$(pgrep -fl -- '--remote-debugging-port' 2>/dev/null |
  sed -n 's|.*/\([^/]*\.app\)/Contents.*|\1|p' | head -1)

if [ -n "$app" ]; then
  ok "serving app: $app"
  case "$app" in
    "Google Chrome.app" | "Google Chrome for Testing.app")
      ok "officially supported build"
      ;;
    *)
      note "NOT an officially supported build. Upstream supports Google Chrome and"
      note "Chrome for Testing only; others \"may work, but this is not guaranteed\"."
      note "Treat it as a first suspect for odd behaviour, never as a proven fault."
      ;;
  esac
else
  note "could not identify the serving app from the process list — note that the"
  note "\"Browser\" string above cannot settle it either: ungoogled-chromium also"
  note "reports Chrome/<version> (measured 2026-09-06)."
fi

say ""
say "reminders"
note "an open debugging port lets ANY local process drive this browser and read its"
note "data — close the window when the session ends"
note "always pass --no-usage-statistics and --no-performance-crux; telemetry is on by"
note "default and the CrUX lookup sends TRACE URLS off-machine"

exit "$rc"
