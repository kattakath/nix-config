# `chrome-automation` (macOS only) — launch a DEDICATED Google Chrome instance for agent
# browser automation: its own profile (log into your sites once, kept separate from your
# main browsing) + a CDP remote-debugging port that the Playwright MCP server attaches to
# (`--cdp-endpoint`, modules/shared/mcp.nix). You keep this window open on another Space and
# glance at it whenever; the agent drives it in parallel while you keep using your main Chrome.
#
#   chrome-automation            # or: nix run .#chrome-automation
#   → opens the automation Chrome (idempotent: focuses it if already running on the port).
#     Log into the sites you want the agent to use, leave it open, then have the agent use
#     the `playwright` MCP tools — they attach to THIS window over CDP.
#
# Chrome refuses --remote-debugging-port on the DEFAULT profile (security), which is exactly
# why this uses a separate --user-data-dir. Port/dir are overridable via env.
{
  writeShellApplication,
  curl,
  coreutils,
}:
writeShellApplication {
  name = "chrome-automation";
  runtimeInputs = [
    curl
    coreutils
  ];
  text = ''
    prog=chrome-automation
    port="''${CHROME_AUTOMATION_PORT:-9222}"
    # Dedicated profile dir (separate from your main "Google/Chrome" profile). $HOME-relative,
    # single place, overridable.
    dir="''${CHROME_AUTOMATION_DIR:-$HOME/Library/Application Support/chrome-automation}"
    cdp="http://127.0.0.1:$port"

    die() { echo "$prog: error: $*" >&2; exit 1; }

    [ -d "/Applications/Google Chrome.app" ] || die "Google Chrome not installed (/Applications/Google Chrome.app)"

    # Idempotent: if the CDP endpoint already answers, it's already running.
    if curl -fsS --max-time 2 "$cdp/json/version" >/dev/null 2>&1; then
      echo "$prog: automation Chrome already running on $cdp — focusing it."
      /usr/bin/open -a "Google Chrome" --args --user-data-dir="$dir" >/dev/null 2>&1 || true
      exit 0
    fi

    mkdir -p "$dir"
    # Launch a SEPARATE, detached instance (own profile + debug port). `open -na` hands it to
    # LaunchServices so it persists independently of this shell/agent. Loopback debug port only.
    /usr/bin/open -na "Google Chrome" --args \
      --user-data-dir="$dir" \
      --remote-debugging-port="$port" \
      --no-first-run \
      --no-default-browser-check \
      || die "failed to launch Google Chrome"

    # Wait briefly for the CDP endpoint to come up so the caller knows it's attachable.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS --max-time 2 "$cdp/json/version" >/dev/null 2>&1; then
        echo "$prog: automation Chrome up — CDP at $cdp (profile: $dir)."
        echo "$prog: log into your sites here, keep it open; the playwright MCP tools attach to it."
        exit 0
      fi
      sleep 1
    done
    echo "$prog: launched, but CDP $cdp did not answer within ~10s — check the Chrome window." >&2
    exit 0
  '';
}
