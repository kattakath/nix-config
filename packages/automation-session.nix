# `automation-session` (macOS only) — the SECURITY half of the disposable automation browser.
# Keeps the agent's browser auth as a Playwright `storageState` ENCRYPTED in the macOS login
# Keychain, and injects/extracts it into/out of the LIVE browser (`chrome-automation`) over CDP.
#
#   automation-session login  [site]   # (first time) headed: you log in, then it CAPTURES → Keychain
#   automation-session seed   [site]   # inject the Keychain session into the running browser
#   automation-session capture [site]  # save the running browser's refreshed session → Keychain
#   automation-session status [site]   # is CDP up? is a Keychain session stored?
#
# WHY Keychain, not a file, not the `secret` auto-export index:
#   * storageState holds LIVE session cookies (credential-grade) — never leave it as plaintext on
#     disk. The login Keychain encrypts at rest and ACL-gates reads.
#   * It is deliberately NOT registered with `secret set` (the nix-keychain-secrets index), because
#     that index is exported into EVERY shell — you do not want a ~large session blob in every
#     process env, paid every shell start. This uses a dedicated, NON-indexed Keychain service,
#     read on demand only. (`secret ls` will not show it — by design.)
#
# The disposable browser (`chrome-automation`, ungoogled-chromium, ephemeral profile) carries NO
# persistent auth; the session of record is this Keychain item. Nuke the profile freely.
{
  writeShellApplication,
  nodejs,
  playwright-driver,
  coreutils,
}:
writeShellApplication {
  name = "automation-session";
  runtimeInputs = [
    nodejs
    coreutils
  ];
  text = ''
    prog=automation-session
    port="''${CHROME_AUTOMATION_PORT:-9222}"
    cdp="http://127.0.0.1:$port"
    export PLAYWRIGHT_CORE=${playwright-driver}
    export CDP_URL="$cdp"
    js=${./automation-session.js}
    sec=/usr/bin/security
    acct="$(/usr/bin/id -un)"

    die() { echo "$prog: error: $*" >&2; exit 1; }

    # Keychain service name: dedicated + NON-indexed. Optional [site] arg namespaces per-site.
    svc="automation-storage-state"
    cmd="''${1:-}"
    site="''${2:-}"
    [ -n "$site" ] && svc="$svc-$site"

    require_cdp() {
      # probe the CDP endpoint via node (node is the only runtime input here, not curl).
      node -e "require('http').get('$cdp/json/version',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" \
        || die "no automation browser on $cdp — run 'chrome-automation' first."
    }

    kc_get() { "$sec" find-generic-password -a "$acct" -s "$svc" -w 2>/dev/null; }
    kc_set() { "$sec" add-generic-password -U -a "$acct" -s "$svc" -w "$1" -D "automation storageState" >/dev/null; }

    case "$cmd" in
      seed)
        require_cdp
        json="$(kc_get)" || die "no Keychain session for '$svc' — run 'automation-session login $site' first."
        [ -n "$json" ] || die "Keychain session '$svc' is empty."
        printf '%s' "$json" | node "$js" seed
        echo "$prog: seeded '$svc' into the live browser."
        ;;
      capture)
        require_cdp
        json="$(node "$js" capture)" || die "capture failed."
        [ -n "$json" ] || die "capture produced empty storageState."
        # NOTE: the JSON is passed to `security -w` on argv (brief ps visibility). `security` has
        # no clean stdin path for the value; acceptable on a single-user Mac. Stored encrypted.
        kc_set "$json"
        echo "$prog: captured live session → Keychain '$svc' ($(printf '%s' "$json" | wc -c | tr -d ' ') bytes)."
        ;;
      login)
        require_cdp
        echo "$prog: in the automation browser window, log in$([ -n "$site" ] && echo " to '$site'")."
        printf "%s: press Enter here once you are fully logged in… " "$prog"
        read -r _
        json="$(node "$js" capture)" || die "capture failed."
        [ -n "$json" ] || die "capture produced empty storageState — are you logged in?"
        kc_set "$json"
        echo "$prog: saved session → Keychain '$svc'. Future launches: chrome-automation → automation-session seed $site."
        ;;
      status)
        if node -e "require('http').get('$cdp/json/version',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"; then
          echo "browser: UP on $cdp"
        else
          echo "browser: down (run chrome-automation)"
        fi
        if kc_get >/dev/null 2>&1 && [ -n "$(kc_get)" ]; then
          echo "keychain '$svc': present ($(kc_get | wc -c | tr -d ' ') bytes)"
        else
          echo "keychain '$svc': none (run automation-session login $site)"
        fi
        ;;
      "" | -h | --help | help)
        echo "usage: $prog <login|seed|capture|status> [site]"
        ;;
      *) die "unknown subcommand '$cmd' (login|seed|capture|status)" ;;
    esac
  '';
}
