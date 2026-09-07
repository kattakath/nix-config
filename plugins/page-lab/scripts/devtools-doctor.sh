#!/usr/bin/env bash
# devtools-doctor.sh — connection preflight for chrome-devtools-mcp.
#
# WHY THIS EXISTS. Almost every "the DevTools tools are broken" report is really one
# of three different things, and they need three different fixes:
#
#   1. no Node / no npx           -> the server cannot start at all
#   2. debugging is off entirely  -> no port is open: turn it on in-browser at
#                                    chrome://inspect/#remote-debugging, or relaunch
#                                    with --remote-debugging-port
#   3. debugging IS on, but the   -> a browser enabled from chrome://inspect serves the
#      /json/* HTTP endpoints        CDP WebSocket and 404s every /json/* path, so
#      are 404 [F-NO-JSON-HTTP]      --browser-url cannot attach. Use --autoConnect
#                                    --userDataDir <profile>, which reads the port out
#                                    of DevToolsActivePort instead
#   4. something IS listening,    -> upstream officially supports Google Chrome and
#      but it is a browser           Chrome for Testing only; other Chromium builds
#      upstream does not support     "may work, but this is not guaranteed"
#
# Guessing between those costs turns. This answers it in one command.
#
#   usage: devtools-doctor.sh [browser-url] [--user-data-dir DIR]
#            defaults: http://127.0.0.1:9222, and the dir is auto-probed from the
#            known fleet profiles when not given
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
USER_DATA_DIR=""
want_dir=0
for arg in "$@"; do
  if [ "$want_dir" = 1 ]; then
    USER_DATA_DIR="$arg"
    want_dir=0
    continue
  fi
  case "$arg" in
    --verify-tools) verify_tools=1 ;;
    --user-data-dir) want_dir=1 ;;
    --user-data-dir=*) USER_DATA_DIR="${arg#*=}" ;;
    -h | --help)
      printf 'usage: devtools-doctor.sh [browser-url] [--user-data-dir DIR] | devtools-doctor.sh --verify-tools\n' >&2
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
say "debugging endpoint"

if ! command -v curl >/dev/null 2>&1; then
  note "curl not on PATH — skipping the endpoint probe"
  exit "$rc"
fi

# Is anything accepting TCP on a loopback port? bash's /dev/tcp needs no extra tool.
listening() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0 || return 1; }

# Which app serves a port. In chrome://inspect consent mode there is no
# --remote-debugging-port in any argv, so the old pgrep discriminator finds nothing
# [F-NO-JSON-HTTP]; the listening socket's owner is the honest answer either way.
serving_app() {
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}'
}

# ---- Mode A: the classic /json/* discovery endpoint (launch-flag browsers) --------
port="${URL##*:}"
port="${port%%/*}"
body=$(curl -fsS --max-time 5 "$URL/json/version" 2>/dev/null || true)

if [ -n "$body" ]; then
  ok "classic mode — $URL/json/version answered"
  ok "--browser-url and --autoConnect will both work"
  browser=$(printf '%s' "$body" | sed -n 's/.*"Browser"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  proto=$(printf '%s' "$body" | sed -n 's/.*"Protocol-Version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$browser" ] && ok "browser: $browser"
  [ -n "$proto" ] && ok "CDP protocol: $proto"
else
  # A 404/empty here is NOT proof the browser is down. A browser switched on from
  # chrome://inspect/#remote-debugging serves the WebSocket and 404s every /json/*
  # path, so this branch must check DevToolsActivePort before reporting anything.
  note "$URL/json/version did not answer — NOT proof debugging is off [F-NO-JSON-HTTP]"

  # Profiles to check: the one the operator named, else the fleet's known dirs.
  if [ -n "$USER_DATA_DIR" ]; then
    candidates="$USER_DATA_DIR"
  else
    candidates="$HOME/Library/Application Support/com.operasoftware.OperaAir
$HOME/Library/Application Support/Chromium
$HOME/Library/Application Support/Google/Chrome"
  fi

  found=0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    f="$dir/DevToolsActivePort"
    [ -r "$f" ] || continue
    dport=$(sed -n 1p "$f" 2>/dev/null | tr -d '[:space:]')
    dws=$(sed -n 2p "$f" 2>/dev/null | tr -d '[:space:]')
    case "$dport" in '' | *[!0-9]*) continue ;; esac
    if listening "$dport"; then
      found=1
      ok "consent mode — debugging live on 127.0.0.1:$dport"
      ok "profile: $dir"
      [ -n "$dws" ] && ok "ws endpoint: ws://127.0.0.1:$dport$dws"
      say ""
      say "  Attach with the profile, not the port — both the port and the ws UUID"
      say "  change on every launch [F-AUTOCONNECT-USERDATADIR]:"
      say "    --autoConnect --userDataDir \"$dir\""
      say ""
      say "  --browser-url CANNOT attach to this browser: /json/version is 404."
      break
    fi
    note "stale DevToolsActivePort in $dir (port $dport not listening) — ignoring"
  done <<EOF
$candidates
EOF

  if [ "$found" = 0 ]; then
    bad "no debugging endpoint — nothing is listening"
    say ""
    say "  Two ways to turn it on. Neither is persistent, both are deliberate:"
    say "    in-browser  chrome://inspect/#remote-debugging  (no relaunch; browser"
    say "                picks its own port and writes DevToolsActivePort)"
    say "    launch flag open -na \"Chromium\" --args --remote-debugging-port=9222"
    say "                (STARTUP only — quit the browser completely first)"
    say ""
    say "  Relaunching while the same profile is still running silently reuses the"
    say "  existing process and the port never opens — which looks like the flag being"
    say "  ignored. Check with: pgrep -fl 'Chromium|Google Chrome|Opera'"
    say ""
    say "  Not attaching? Then this is fine: in launch mode the server starts its own"
    say "  browser and needs no endpoint."
    exit 1
  fi
  port="$dport"
fi

# The build string does NOT identify the vendor [F-UGC-NO-VENDOR]: ungoogled-chromium
# reports "Chrome/152.0.7977.64", identical in shape to Google Chrome, and
# /json/version carries no vendor field. Only the process holding the socket can settle it.
app=$(serving_app "$port")

if [ -n "$app" ]; then
  ok "serving app: $app"
  case "$app" in
    "Google Chrome" | "Google Chrome for Testing")
      ok "officially supported build"
      ;;
    *)
      note "NOT an officially supported build. Upstream supports Google Chrome and"
      note "Chrome for Testing only; others \"may work, but this is not guaranteed\"."
      note "Treat it as a first suspect for odd behaviour, never as a proven fault."
      ;;
  esac
else
  note "could not identify the serving app (no lsof, or the socket is not visible) —"
  note "note that a \"Browser\" build string cannot settle it either: ungoogled-chromium"
  note "also reports Chrome/<version> [F-UGC-NO-VENDOR]."
fi

say ""
say "reminders"
note "an open debugging port lets ANY local process drive this browser and read its"
note "data — close the window when the session ends"
note "always pass --no-usage-statistics and --no-performance-crux; telemetry is on by"
note "default and the CrUX lookup sends TRACE URLS off-machine"

exit "$rc"
