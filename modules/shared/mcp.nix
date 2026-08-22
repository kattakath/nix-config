# Private, localhost-only MCP gateway for Claude Code (darwin / the Mac).
#
# WHAT THIS DOES
# Instead of every MCP client (Claude Code, Cursor, Claude Desktop) spawning its
# OWN stdio copy of each server per session, we run ONE shared instance of each
# server behind sparfenyuk/mcp-proxy — a launchd USER agent bound to 127.0.0.1,
# started at login (RunAtLoad) and kept alive. Clients connect over HTTP to a
# single long-lived process per server: shared memory-graph state, one cache, no
# duplicate spawns, always up. Nothing listens off-box (host is 127.0.0.1 — no
# tunnel, no Access). `desktop-commander` is deliberately EXCLUDED from the
# gateway (shell/RCE surface) and stays a per-client stdio server.
#
# REQUIREMENT: a launchd USER (GUI) agent lives in the `gui/<uid>` domain, which
# only exists while that uid has an active GUI login. This targets the flake
# `loginName` (uid 502), so that account must be the one logged into the Mac —
# which it is (the active console user is `ismail`). If a different
# account owns the GUI session, `darwin-rebuild switch` cannot load the agent.
#
# SERVER SIDE (this box, 127.0.0.1:8096)
#   `mcp-proxy --named-server-config <gatewayConfig>` hosts all 19 servers (21
#   with telegram + the local WordPress adapter, +1 per configured
#   `services.mcpGateway.gmail.accounts` alias — `gmail-<alias>`, one process
#   per Google/Workspace account, 0 in this public repo — see mkGmailMcp's
#   comment), each reachable at /servers/<name>/sse.
#   `gatewayConfig` is rendered by mcp-servers-nix's `lib.mkConfig`, so the 7 packaged
#   servers (context7/fetch/memory/sequential-thinking/nixos/terraform/github) are
#   PINNED store-path commands; the 12 without a module (+ telegram / the local
#   WordPress adapter / gmail-<alias> when configured) fall
#   back to pinned npx/uvx launchers (still a runtime fetch, but acceptable on the Mac
#   where Node/uv already live).
#
# CLIENT SIDE (programs.claude-code.mcpServers)
#   The 19 hosted servers (21+ with every opt-in) are wired as `type = "http"` (Streamable HTTP — the
#   current MCP standard; the legacy HTTP+SSE transport was deprecated in the
#   2025-03-26 spec) pointing at /servers/<name>/mcp; desktop-commander stays
#   `type = "stdio"`. The claude-code module writes these into a managed
#   .mcp.json plugin dir — it does NOT clobber the stateful ~/.claude.json.
#   mcp-proxy serves BOTH /mcp and /sse per server concurrently, so an SSE-only
#   client (e.g. Grok) just points its OWN config at `endpointFor <name> "sse"`.
#
# SCOPE: darwin only (the Mac is the sole MCP client host; keeps the Pi/VM lean).
# There is no project ./.mcp.json — this user-scope gateway is the single source.
{
  pkgs,
  lib,
  config,
  mcp-servers-nix,
  ...
}:
let
  cfg = config.services.mcpGateway;

  # localhost-only gateway endpoint.
  gatewayHost = "127.0.0.1";
  gatewayPort = 8096;

  # Android SDK root — single-sourced from modules/shared/home.nix's ANDROID_HOME
  # (the android-commandlinetools Homebrew cask install prefix), not re-declared
  # here. mobile-mcp locates `adb` via $ANDROID_HOME/platform-tools, so the
  # gateway launchd agent below puts this on PATH + exports ANDROID_HOME (unlike
  # osascript, adb is NOT in the base PATH).
  androidSdkHome = config.home.sessionVariables.ANDROID_HOME;

  # Pinned launchers for the servers mcp-servers-nix does not package. Absolute
  # store paths so they resolve under launchd's minimal PATH.
  npx = lib.getExe' pkgs.nodejs "npx";
  uvx = lib.getExe' pkgs.uv "uvx";

  # chaindead/telegram-mcp (Go, MIT) speaks MTProto as YOUR Telegram USER account —
  # it reads/triages DMs, private groups and channels, and DRAFTS replies
  # (`messages.saveDraft`; you press send — nothing posts under your name). It needs
  # the TG_APP_ID/TG_API_HASH application pair (from my.telegram.org) plus a one-time
  # phone-code login that writes a SESSION file. Those are account credentials, so —
  # like the cloudflared connector and the context7/github tokens — the API pair is
  # read from the login Keychain at LAUNCH by this wrapper (never in argv or the
  # /nix/store) and exported before exec. The session file is host-key-independent
  # local state at ~/.telegram-mcp/session.json (pinned via TG_SESSION_PATH so the
  # launchd subprocess finds it regardless of its cwd; HOME is set for the same
  # reason). The server REFUSES to start without a session, so this is opt-in
  # (services.mcpGateway.telegram.enable) and must be enabled only AFTER the one-time
  # auth below — a server that exits at startup could dark the whole gateway. Basename
  # nix-* for the BTM origin rule. Store the pair + auth once:
  #     secret set TG_APP_ID <app_id> ; secret set TG_API_HASH <api_hash>
  #     npx -y @chaindead/telegram-mcp auth --app-id <id> --api-hash <hash> --phone +<number>
  telegramMcp = pkgs.writeShellScriptBin "nix-telegram-mcp" ''
    set -eu
    app_id="$(/usr/bin/security find-generic-password -a "$(id -un)" -s TG_APP_ID -w 2>/dev/null || true)"
    api_hash="$(/usr/bin/security find-generic-password -a "$(id -un)" -s TG_API_HASH -w 2>/dev/null || true)"
    session="${config.home.homeDirectory}/.telegram-mcp/session.json"
    if [ -z "$app_id" ] || [ -z "$api_hash" ] || [ ! -f "$session" ]; then
      echo "telegram-mcp: missing TG_APP_ID/TG_API_HASH in the login Keychain and/or the session file." >&2
      echo "  1) Get an API pair at https://my.telegram.org (API development tools), then:" >&2
      echo "       secret set TG_APP_ID <app_id>" >&2
      echo "       secret set TG_API_HASH <api_hash>" >&2
      echo "  2) Authenticate ONCE (phone code) — creates $session:" >&2
      echo "       ${npx} -y @chaindead/telegram-mcp auth --app-id <app_id> --api-hash <api_hash> --phone +<number>" >&2
      exit 1
    fi
    export TG_APP_ID="$app_id"
    export TG_API_HASH="$api_hash"
    export HOME="${config.home.homeDirectory}"
    export TG_SESSION_PATH="$session"
    exec ${npx} -y @chaindead/telegram-mcp
  '';

  # ArtyMcLabin/Gmail-MCP-Server (maintained fork of the now-archived
  # GongRzhe/Gmail-MCP-Server, verified 2026-08-19: 226 stars, pushed a week
  # prior, MIT). TRUE simultaneous multi-account access — the built-in Gmail
  # connector is single-account-per-connection by design; this instead runs ONE
  # server process PER Google/Workspace account, each with its own
  # `--tool-prefix` (the project's own documented fix for "MCP clients dedupe
  # tool entries by base name across servers", which otherwise makes two
  # side-by-side instances impossible) so `gmail-<alias>` exposes
  # `<alias>_search_emails` etc. without colliding with any other account.
  #
  # cfg.gmail.accounts is a list of PLAIN EMAIL ADDRESSES (the actual config
  # surface — no invented nicknames to keep track of). MCP tool names and
  # --tool-prefix can't contain "@"/"." though, so `gmailAlias` below derives
  # a sanitized token from each email purely for the prefix/filename/arg0 —
  # an internal detail, not something you need to think about when editing
  # the account list.
  gmailAlias = email: lib.toLower (lib.replaceStrings [ "@" "." "+" ] [ "_" "_" "_" ] email);

  # ONE shared Google Cloud OAuth "Desktop app" client (client_id/client_secret
  # — Google allows the same Desktop client to authenticate multiple accounts)
  # is read from the login Keychain at LAUNCH and materialized into
  # ~/.gmail-mcp/gcp-oauth.keys.json in the exact shape Google's own downloaded
  # credentials JSON uses (never in argv/the store — same shape as
  # telegramMcp/wpMcp above). Each account gets its OWN GMAIL_CREDENTIALS_PATH —
  # populated by a SEPARATE one-time interactive `auth` run per account (opens a
  # browser; the tool itself writes that file, this wrapper never touches it).
  #
  # WHICH accounts run is cfg.gmail.accounts, empty by default and
  # deliberately NOT populated here — real email addresses are personal data
  # that doesn't belong in a public repo, and several of the accounts this
  # was built for aren't even the operator's own (family/associates whose
  # inboxes he manages). The real list is supplied by the PRIVATE nix-personal
  # composition flake via `extraHomeModules`, same contract as nixpi's
  # `hostedSites` (docs/private-home-modules.md) — public `hosts/macos.nix`
  # passes only its own two already-public addresses. An account with no
  # completed auth exits at startup, so only add an email here AFTER its
  # one-time browser login is done. Basename nix-* for the BTM origin rule.
  # Setup once (shared client), then once per account:
  #     secret set GMAIL_OAUTH_CLIENT_ID <client_id>
  #     secret set GMAIL_OAUTH_CLIENT_SECRET <client_secret>
  #     # Google Cloud Console -> APIs & Services -> Credentials -> Create
  #     # Credentials -> OAuth client ID -> Desktop app -> enable the Gmail API.
  #     nix-mcp-gmail-<sanitized-email>   # launch once to materialize
  #       # gcp-oauth.keys.json, then Ctrl-C (arg0 shown at gateway launch, or
  #       # just lowercase the email and replace "@"/"."/"+" with "_")
  #     GMAIL_OAUTH_PATH=~/.gmail-mcp/gcp-oauth.keys.json \
  #       GMAIL_CREDENTIALS_PATH=~/.gmail-mcp/credentials-<sanitized-email>.json \
  #       npx -y @artymclabin/gmail-mcp auth
  mkGmailMcp =
    {
      arg0,
      prefix,
      credentialsFile,
    }:
    pkgs.writeShellScriptBin arg0 ''
            set -u
            dir="${config.home.homeDirectory}/.gmail-mcp"
            mkdir -p "$dir"
            client_id="$(/usr/bin/security find-generic-password -a "$(id -un)" -s GMAIL_OAUTH_CLIENT_ID -w 2>/dev/null || true)"
            client_secret="$(/usr/bin/security find-generic-password -a "$(id -un)" -s GMAIL_OAUTH_CLIENT_SECRET -w 2>/dev/null || true)"
            if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
              echo "${arg0}: missing GMAIL_OAUTH_CLIENT_ID/GMAIL_OAUTH_CLIENT_SECRET in the login Keychain — tools will fail until set (see the setup note in mcp.nix)." >&2
            fi
            oauth_keys="$dir/gcp-oauth.keys.json"
            cat > "$oauth_keys" <<JSON
      {"installed":{"client_id":"$client_id","client_secret":"$client_secret","redirect_uris":["http://localhost"]}}
      JSON
            chmod 600 "$oauth_keys"
            export GMAIL_OAUTH_PATH="$oauth_keys"
            export GMAIL_CREDENTIALS_PATH="$dir/${credentialsFile}"
            export HOME="${config.home.homeDirectory}"
            exec ${npx} -y @artymclabin/gmail-mcp --tool-prefix=${prefix}_
    '';

  # One wrapper per configured email (cfg.gmail.accounts — see mkGmailMcp's
  # comment for why the list itself lives in the private nix-personal flake).
  # Keyed by the RAW email (genAttrs uses list elements as attr names); the
  # sanitized gmailAlias is only used for the derivation's internal naming.
  gmailMcps = lib.genAttrs cfg.gmail.accounts (
    email:
    mkGmailMcp {
      arg0 = "nix-mcp-gmail-${gmailAlias email}";
      prefix = gmailAlias email;
      credentialsFile = "credentials-${gmailAlias email}.json";
    }
  );

  # WordPress site administration over the REST API (docdyhr/mcp-wordpress, ~59
  # tools, PINNED). CLIENT-SIDE: it talks to the LIVE site's /wp-json with an
  # Application Password — NOTHING is installed on the WordPress site itself. The
  # three creds are read from the login Keychain at launch and mapped to the
  # server's WORDPRESS_* env, so no secret ever lands in the gateway JSON / store /
  # argv (same shape as telegramMcp above). Store them once:
  #     secret set WP_URL <https://www.SITE>   # MUST be the canonical www host —
  #       a non-www host that 301-redirects cross-host DROPS the Authorization
  #       header, so REST auth 401s. secret set WP_ADMIN_USER <login> ;
  #     secret set WP_ADMIN_APP_PASSWORD <app-pw>   # wp-admin ▸ Users ▸ Profile ▸
  #       Application Passwords — NOT the login password (WP refuses it for REST).
  # Resilient by design: on missing creds it warns but STILL execs, so an absent
  # secret can't dark the shared gateway (unlike telegram, which exits). Basename
  # nix-* for the BTM origin rule.
  wpMcp = pkgs.writeShellScriptBin "nix-mcp-wordpress" ''
    set -u
    site="$(/usr/bin/security find-generic-password -a "$(id -un)" -s WP_URL -w 2>/dev/null || true)"
    user="$(/usr/bin/security find-generic-password -a "$(id -un)" -s WP_ADMIN_USER -w 2>/dev/null || true)"
    pass="$(/usr/bin/security find-generic-password -a "$(id -un)" -s WP_ADMIN_APP_PASSWORD -w 2>/dev/null || true)"
    if [ -z "$site" ] || [ -z "$user" ] || [ -z "$pass" ]; then
      echo "mcp-wordpress: missing WP_URL / WP_ADMIN_USER / WP_ADMIN_APP_PASSWORD in the login Keychain — tools will fail until set (see the store-them-once note in mcp.nix)." >&2
    fi
    export WORDPRESS_SITE_URL="$site"
    export WORDPRESS_USERNAME="$user"
    export WORDPRESS_APP_PASSWORD="$pass"
    export HOME="${config.home.homeDirectory}"
    exec ${npx} -y mcp-wordpress@3.3.30
  '';

  # Official WordPress MCP Adapter (WordPress/mcp-adapter), installed ON the site,
  # exposing a Streamable-HTTP MCP endpoint at /wp-json/mcp/mcp-adapter-default-server
  # (default server = 3 meta-tools: discover / get-info / execute Ability — so any core
  # or plugin Ability becomes agent-callable). SERVER-SIDE, complementary to the client-
  # side `wordpress` (docdyhr) server above. Reached with `mcp-remote` pointed DIRECTLY
  # at that path — Automattic's mcp-wordpress-remote proxy targets the LEGACY wpmcp
  # route and 404s on the adapter. Auth is HTTP Basic reusing the SAME admin creds as
  # `wordpress` (WP_ADMIN_USER + WP_ADMIN_APP_PASSWORD from the login Keychain; verified
  # against prod AND the local wp-env clone, whose DB is a prod copy so the one app
  # password authenticates on both). The Basic header is built into an env var and
  # passed via mcp-remote's single-quoted ''${ENV} expansion, so the secret never lands
  # in argv / the /nix/store / the gateway JSON. Resilient: warns but still execs on a
  # missing secret. Basename nix-* for the BTM origin rule.
  mkWpAdapterMcp =
    {
      arg0,
      apiUrl,
      allowHttp ? false,
    }:
    pkgs.writeShellScriptBin arg0 ''
      set -u
      user="$(/usr/bin/security find-generic-password -a "$(id -un)" -s WP_ADMIN_USER -w 2>/dev/null || true)"
      pass="$(/usr/bin/security find-generic-password -a "$(id -un)" -s WP_ADMIN_APP_PASSWORD -w 2>/dev/null || true)"
      if [ -z "$user" ] || [ -z "$pass" ]; then
        echo "${arg0}: missing WP_ADMIN_USER / WP_ADMIN_APP_PASSWORD in the login Keychain — adapter tools will fail until set." >&2
      fi
      pass="$(printf '%s' "$pass" | tr -d ' ')"
      export WP_ADAPTER_AUTH="Basic $(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')"
      export HOME="${config.home.homeDirectory}"
      exec ${npx} -y mcp-remote@latest ${apiUrl}/wp-json/mcp/mcp-adapter-default-server${lib.optionalString allowHttp " --allow-http"} --header 'Authorization: ''${WP_ADAPTER_AUTH}'
    '';

  wpAdapterMcp = mkWpAdapterMcp {
    arg0 = "nix-mcp-wp-adapter";
    apiUrl = "https://www.silvercreek.ai";
  };

  wpAdapterMcpLocal = mkWpAdapterMcp {
    arg0 = "nix-mcp-wp-adapter-local";
    apiUrl = "http://localhost:8888";
    allowHttp = true;
  };

  # Apify's Actors MCP server (apify/actors-mcp-server), run LOCALLY via
  # APIFY_TOKEN — NOT the hosted mcp.apify.com OAuth bridge the `apify` entry
  # below used until 2026-08-19. That OAuth flow needs an interactive browser
  # redirect on first use, which a headless launchd agent can never complete;
  # confirmed stuck in mcp-gateway.log re-issuing a fresh PKCE challenge on
  # every connection attempt with no way to finish it. The token authenticates
  # at LAUNCH via `security` (never in argv / never in the store), matching the
  # wpMcp/telegramMcp Keychain-wrapper shape above. Resilient like wpMcp: warns
  # but still execs on a missing token, so an absent secret can't dark the
  # shared gateway. Basename nix-* for the BTM origin rule. Store it once:
  #     secret set APIFY_TOKEN <token>   # Apify Console → Settings → Integrations
  apifyMcp = pkgs.writeShellScriptBin "nix-mcp-apify" ''
    set -u
    token="$(/usr/bin/security find-generic-password -a "$(id -un)" -s APIFY_TOKEN -w 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "mcp-apify: missing APIFY_TOKEN in the login Keychain — tools will fail until set (secret set APIFY_TOKEN <token>)." >&2
    fi
    export APIFY_TOKEN="$token"
    exec ${npx} -y @apify/actors-mcp-server
  '';

  # The servers with no mcp-servers-nix module, as raw stdio commands. Merged into
  # the gateway config via mkConfig's `settings.servers` (telegram appended below,
  # opt-in). The 12 base ones fall back to pinned npx/uvx launchers; postgres and
  # wordpress are special (pinned version + Keychain-injected env via a wrapper).
  customStdioServers = {
    duckduckgo = {
      command = uvx;
      args = [ "duckduckgo-mcp-server" ];
    };
    json-yaml-toml = {
      command = uvx;
      args = [ "mcp-json-yaml-toml" ];
    };
    mcp-jq = {
      command = npx;
      args = [ "@247arjun/mcp-jq" ];
    };
    # MCP-server DISCOVERY (mcpfinder.dev — @mcpfinder/server, AGPL-3.0):
    # cross-registry search over the Official MCP Registry + Glama + Smithery
    # via `search_mcp_servers` / `get_mcp_server_details`. Wired
    # DISCOVERY-ONLY: its third tool, `add_mcp_server_config`, writes client
    # config files imperatively — the exact anti-pattern this gateway exists
    # to avoid (a server is ADOPTED by declaring it in this file, pinned, and
    # rebuilding — the `mcp-scout` skill in nix-config codifies that flow).
    # That tool is deny-listed in nix-config's .claude/settings.json (mirror
    # the deny in the user-scope settings via nix-personal for other repos);
    # the HM-managed client configs are store symlinks anyway, so a stray
    # write attempt fails closed. Version PINNED: one server that crashes at
    # startup darks the whole gateway (see postgres below) — bump deliberately.
    mcpfinder = {
      command = npx;
      args = [
        "-y"
        "@mcpfinder/server@1.1.0"
      ];
    };
    cloudflare-docs = {
      command = npx;
      args = [
        "-y"
        "mcp-remote"
        "https://docs.mcp.cloudflare.com/mcp"
      ];
    };
    cloudflare = {
      command = npx;
      args = [
        "-y"
        "mcp-remote"
        "https://mcp.cloudflare.com/mcp"
        # mcp.cloudflare.com's oauth-authorization-server metadata omits
        # scopes_supported, so mcp-remote falls back to a hardcoded
        # "openid email profile" scope request — Cloudflare's /authorize
        # rejects that ("Unknown OAuth scope") since it validates against its
        # own product-scope catalog (user:read, account:read, zone:read, …),
        # not OIDC scopes. mcp-remote also treats an empty string as unset
        # (falls through to the same bad default), so pass Cloudflare's own
        # REQUIRED_SCOPES (github.com/cloudflare/mcp src/auth/scopes.ts) as
        # the minimum valid, non-empty override — the browser consent screen
        # still lets you pick additional scopes interactively.
        "--static-oauth-client-metadata"
        ''{"scope":"user:read offline_access account:read"}''
      ];
    };
    # Apify Store's thousands of ready-made Actors (scrapers/crawlers/automation
    # for social media, search engines, maps, e-commerce, any website) as tools,
    # plus Actor search/run/dataset access. Command is the Keychain-injecting
    # apifyMcp wrapper above — see it for why this is the LOCAL token-based
    # server rather than the hosted mcp.apify.com OAuth bridge (used until
    # 2026-08-19, permanently stuck under headless launchd).
    apify = {
      command = lib.getExe apifyMcp;
      args = [ ];
    };
    # Native macOS automation: run AppleScript AND JXA (JavaScript for Automation)
    # through osascript, plus a built-in knowledge base of ready scripts, via the
    # `execute_script` tool. steipete/macos-automator-mcp (854★, actively maintained;
    # clear provenance — the unscoped `applescript-mcp` npm pkg lists no repo). This
    # is a POWERFUL surface (execute_script can `do shell script` and drive any app) —
    # but localhost-only like the rest of the gateway (127.0.0.1, no off-box exposure),
    # and unlike desktop-commander we DO share it across clients (incl. Grok) by
    # request. First control of another app triggers a one-time macOS TCC "Automation"
    # consent prompt. `--package … <bin>` is the maintainer's recommended npx form
    # (sidesteps scoped-package bin inference). Runs under the gateway's GUI launchd
    # agent, so osascript has a real user session.
    #
    # ACCESSIBILITY (TCC): System Events UI scripting additionally needs an
    # Accessibility grant for /usr/bin/osascript — the stable, Apple-signed binary
    # this server's PATH resolves `osascript` to (nothing earlier on the gateway
    # PATH provides it). No app in the launchd chain can raise the consent prompt,
    # so it is a ONE-TIME manual grant (⇧⌘G → /usr/bin/osascript in System Settings
    # ▸ Privacy & Security ▸ Accessibility). It survives every rebuild because the
    # grant target is a fixed system path, NOT a store path — see the preflight in
    # `home.activation.macosAutomatorAccessibilityCheck` below and the full
    # rationale (incl. why no stable-path launchd wrapper helps) in
    # docs/mcp-gateway-accessibility-tcc.md.
    macos-automator = {
      command = npx;
      args = [
        "-y"
        "--package"
        "@steipete/macos-automator-mcp"
        "macos-automator-mcp"
      ];
    };
    # Cross-platform mobile automation — drives Android EMULATORS and physical
    # devices over ADB (plus iOS), accessibility-first (native a11y tree: no vision
    # model, no API key, no image tokens), falling back to screenshots+coordinates.
    # mobile-next/mobile-mcp (5.5k★, Apache-2.0, ~79k dl/mo). Needs `adb` + the
    # Android SDK, so the gateway agent below adds ${androidSdkHome}/platform-tools to
    # PATH and exports ANDROID_HOME. Drives any booted `android-emu`
    # (modules/shared/home.nix) or a USB device with debugging authorized — the adb
    # server (:5037) is shared per-user, so the gateway and the emulator see each other.
    mobile-mcp = {
      command = npx;
      args = [
        "-y"
        "@mobilenext/mobile-mcp@latest"
      ];
    };
    # Local Postgres + pgvector, for vector-similarity / RAG work. crystaldba's
    # `postgres-mcp` ("Postgres MCP Pro", actively maintained) — a general SQL
    # executor, so every pgvector op (`<->`/`<=>` distance, HNSW indexes) is just
    # SQL it can run. (The official @modelcontextprotocol/server-postgres is ARCHIVED
    # with an unpatched read-only-bypass SQL-injection CVE — deliberately avoided.)
    # `--access-mode=unrestricted` lets it create tables + insert/query vectors; the
    # blast radius is bounded not by that flag but by DATABASE_URI's role `mcp`, which
    # owns ONLY `ragdb` and connects loopback-trust with no secret. The DB is a
    # loopback launchd agent — from the extracted local-rag flake
    # (github:ismailkattakath/nix-local-rag), which single-sources the URI via
    # services.pgvectorLocal.databaseUri.
    #
    # This server is a `uvx` RUNTIME fetch (no nixpkgs/mcp-servers-nix package exists),
    # so its resolution can DRIFT — and because mcp-proxy spawns every named server at
    # startup, ONE server that fails to install/import crashes the whole gateway (nothing
    # binds :8096, ALL servers go dark). Two load-bearing pins guard the two ways it drifts:
    #
    # 1. `--python 3.12`: postgres-mcp depends on pglast, whose current release ships no
    #    wheel for CPython 3.14 (uv's default newest interpreter) and fails to source-build
    #    it. 3.12 selects a Python with prebuilt pglast wheels, so it installs in ms.
    # 2. `--with mcp<2` + `--from postgres-mcp==0.3.0`: mcp 2.0.0 (2026-08) REMOVED the
    #    vendored `mcp.server.fastmcp`, but postgres-mcp 0.3.0 still does
    #    `from mcp.server.fastmcp import FastMCP`. Unbounded `uvx postgres-mcp` grabbed the
    #    fresh mcp 2.0 and every import crashed → gateway dark. Constrain mcp to 1.x (which
    #    still ships fastmcp) and pin the postgres-mcp version so the pair stays deterministic.
    #    Bump both together deliberately once postgres-mcp supports mcp 2.x.
    postgres = {
      command = uvx;
      args = [
        "--python"
        "3.12"
        "--with"
        "mcp<2"
        "--from"
        "postgres-mcp==0.3.0"
        "postgres-mcp"
        "--access-mode=unrestricted"
      ];
      env.DATABASE_URI = config.services.pgvectorLocal.databaseUri;
    };
    # WordPress admin for the live site over its REST API — command is the
    # Keychain-injecting wpMcp wrapper above, so no secret lands in the gateway JSON.
    wordpress = {
      command = lib.getExe wpMcp;
      args = [ ];
    };
    # Official WordPress MCP Adapter (server-side) for PROD silvercreek.ai — command is
    # the Keychain-injecting mcp-remote wrapper above, so no secret lands in the gateway
    # JSON. Prod is always reachable, so it's a normal (non-gated) hosted server.
    wordpress-adapter = {
      command = lib.getExe wpAdapterMcp;
      args = [ ];
    };
  }
  # Opt-in (default off): the Telegram USER-account server. Its command is the
  # Keychain-exporting wrapper above, so no secret ever lands in the gateway JSON.
  # Excluded from `hostedServerNames` entirely when disabled, so its absence costs
  # nothing and it can't dark the gateway before the one-time auth is done.
  // lib.optionalAttrs cfg.telegram.enable {
    telegram = {
      command = lib.getExe telegramMcp;
      args = [ ];
    };
  }
  # TRUE simultaneous multi-account Gmail — one server process PER configured
  # email (see mkGmailMcp above for why, and why the list itself lives in the
  # private nix-personal flake, not here). Empty cfg.gmail.accounts (the
  # public default) makes this an empty attrset, costing nothing. Server name
  # uses the sanitized gmailAlias, not the raw email (gmailMcps' attr key) —
  # named-server-config entries can't contain "@"/".".
  // lib.mapAttrs' (
    email: mcp:
    lib.nameValuePair "gmail-${gmailAlias email}" {
      command = lib.getExe mcp;
      args = [ ];
    }
  ) gmailMcps
  // lib.optionalAttrs cfg.localAdapter.enable {
    # Opt-in (default off): the SAME adapter against the LOCAL wp-env clone
    # (http://localhost:8888). Gated because that endpoint only exists while the clone
    # runs; mcp-proxy spawns every named server at startup, so wiring an unreachable
    # endpoint risks a startup-failing server on the shared gateway. Enable only while
    # working against the local clone.
    wordpress-adapter-local = {
      command = lib.getExe wpAdapterMcpLocal;
      args = [ ];
    };
  };

  # Every server NAME the gateway hosts (7 packaged + 12 base custom, plus
  # opt-ins). Single source
  # for the client SSE URLs, so the two sides can never drift. Order/names MUST
  # match the packaged servers enabled in `gatewayConfig.programs` below.
  packagedServerNames = [
    "context7"
    "fetch"
    "memory"
    "sequential-thinking"
    "nixos"
    "terraform"
    "github"
  ];
  hostedServerNames = packagedServerNames ++ builtins.attrNames customStdioServers;

  # SERVER SIDE: a {mcpServers:{name:{command,args,env}}} JSON that mcp-proxy
  # consumes via --named-server-config. mkConfig PINS the 7 packaged servers;
  # settings.servers carries the 12 custom ones verbatim. flavor "claude-code"
  # emits the `mcpServers` key mcp-proxy expects (it ignores any extra fields).
  gatewayConfig = mcp-servers-nix.lib.mkConfig pkgs {
    flavor = "claude-code";
    fileName = "mcp-gateway.json";
    programs = {
      context7 = {
        enable = true;
        # An API key raises context7's rate limits. Fetched at gateway LAUNCH from
        # the login Keychain (`set-secret CONTEXT7_API_KEY <key>`) by the module's
        # passwordCommand wrapper, which does `export CONTEXT7_API_KEY=$(security …)`
        # then execs context7-mcp — so the value is NEVER in argv or the /nix/store
        # (same pattern as the cloudflared connector above). context7-mcp reads the
        # env var (`cliOptions.apiKey || process.env.CONTEXT7_API_KEY`); an absent
        # key => empty export => it runs unauthenticated exactly as before. No
        # ~/.zprofile export is needed — the wrapper reads the Keychain itself, and
        # launchd user agents don't source login shells anyway.
        passwordCommand.CONTEXT7_API_KEY = [
          "/usr/bin/security"
          "find-generic-password"
          "-a"
          "$(id -un)"
          "-s"
          "CONTEXT7_API_KEY"
          "-w"
        ];
      };
      # The framework's DEFAULT mcp-server-fetch is 2026.1.26, which calls httpx
      # `AsyncClient(proxies=…)` — a kwarg httpx 0.28 renamed to `proxy` — so every fetch
      # crashed ("unexpected keyword argument 'proxies'"). This flake's top-level nixpkgs
      # ships mcp-server-fetch 2026.7.10, already fixed to `proxy=`; use that build instead.
      fetch = {
        enable = true;
        package = pkgs.mcp-server-fetch;
      };
      memory.enable = true;
      sequential-thinking.enable = true;
      # Grounded, READ-ONLY nixpkgs/NixOS/Home-Manager/nix-darwin option+package lookup
      # (utensils/mcp-nixos). This repo authors config for exactly those three module
      # surfaces every session; a real lookup kills hallucinated package/option names.
      # No token. Kept Nix-built/pinned (not a uvx runtime fetch) for reproducibility;
      # mcp-nixos 2.4.3's `test_read_text_file` is brittle on aarch64-darwin (it asserts
      # a sampled /nix/store text file contains no "Error" substring — a false positive,
      # unrelated to the server), so doCheck is disabled just to let it build.
      nixos = {
        enable = true;
        package = pkgs.mcp-nixos.overrideAttrs (_: {
          doCheck = false;
          doInstallCheck = false;
        });
      };
      # Terraform Registry provider/module/policy schema docs (hashicorp/terraform-mcp-server)
      # for the terranix → Cloudflare IaC under infra/. Registry-docs only (no HCP/TFE token
      # supplied) => read-only. mcp-proxy hosts it like the rest.
      terraform.enable = true;
      # GitHub's official MCP server (typed PR/CI/issue/code-search tools) — more reliable
      # than scraping `gh` output for the one-PR-per-session + GitHub-hosted-CI flow. The PAT
      # is fetched at gateway LAUNCH from the login Keychain via passwordCommand (same pattern
      # as context7 above), so it is NEVER in argv or the /nix/store. Set it once with
      # `secret set GITHUB_PERSONAL_ACCESS_TOKEN <pat>`; an absent key => empty export => the
      # server starts but its calls fail auth until a token is present (it degrades, not crashes).
      github = {
        enable = true;
        passwordCommand.GITHUB_PERSONAL_ACCESS_TOKEN = [
          "/usr/bin/security"
          "find-generic-password"
          "-a"
          "$(id -un)"
          "-s"
          "GITHUB_PERSONAL_ACCESS_TOKEN"
          "-w"
        ];
      };
    };
    settings.servers = customStdioServers;
  };

  # Gateway URL for a server + transport path. transport "mcp" = Streamable HTTP
  # (current standard); "sse" = legacy, still served for SSE-only clients (Grok
  # et al.) — point their own config at `endpointFor <name> "sse"`. Single source
  # of truth for every client's URLs.
  endpointFor =
    name: transport: "http://${gatewayHost}:${toString gatewayPort}/servers/${name}/${transport}";

  # CLIENT SIDE: shape each hosted URL into a Streamable HTTP entry. The URL is
  # already built (in the `endpoints` option); this only wraps it as data.
  httpEntries = lib.mapAttrs (_: url: {
    type = "http";
    inherit url;
  }) cfg.endpoints;

  # VS Code uses `servers` as the top-level key (NOT `mcpServers` — a mismatch VS
  # Code silently ignores) and takes `type = "http"` directly, so it connects to
  # the SAME gateway processes as claude-code. Same hosted servers, no desktop-commander.
  vscodeMcpJson = builtins.toJSON { servers = httpEntries; };

  # Grok CLI (xAI, grok 0.2.x) is a 4th MCP client living OUTSIDE Nix: a self-updating
  # binary at ~/.grok/bin/grok (on PATH via home.sessionPath), config at ~/.grok/config.toml.
  # That file is STATEFUL (grok writes [cli] installer/channel, UI prefs, sessions; auth is
  # in a sibling auth.json), so — exactly like Claude Desktop — we never own the whole file:
  # we delegate the MERGE to the tool that authors the format. `grok mcp add` is add-or-update
  # (idempotent), runs purely OFFLINE (exit 0, no daemon — it only writes TOML), and rewrites
  # ONLY the [mcp_servers.<name>] table. Grok speaks Streamable HTTP natively (--transport http),
  # so it consumes the SAME cfg.endpoints /mcp URLs every other client uses (no SSE fallback).
  # Reuses cfg.endpoints, so Grok can never drift from the gateway.
  grokBin = "${config.home.homeDirectory}/.grok/bin/grok";
  # Loopback gateway URL prefix — the marker identifying entries WE manage, so stale-entry
  # pruning below never touches a user's own (non-gateway) MCP servers.
  grokGatewayPrefix = "http://${gatewayHost}:${toString gatewayPort}/servers/";
  # One idempotent `grok mcp add` per endpoint. `|| true` keeps a rebuild from aborting on a
  # transient grok error (best-effort, self-heals next switch; `mcp add` only writes TOML, so
  # a down gateway does NOT make it fail).
  grokAddLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: url:
      ''"$grok" mcp add --transport http --scope user ${lib.escapeShellArg name} ${lib.escapeShellArg url} >/dev/null 2>&1 || true''
    ) cfg.endpoints
  );
  # Space-padded desired-name set for the prune membership test.
  grokDesiredNames = lib.concatStringsSep " " (builtins.attrNames cfg.endpoints);
in
{
  options.services.mcpGateway = {
    enable =
      lib.mkEnableOption "the localhost MCP gateway (a sparfenyuk mcp-proxy launchd user agent hosting the shared packaged + custom MCP servers on 127.0.0.1)"
      // {
        # The Mac is the sole MCP client host; inert (nothing emitted) on the Pi/VM.
        # Reproduces today's `lib.mkIf pkgs.stdenv.isDarwin` gate exactly.
        default = pkgs.stdenv.isDarwin;
      };

    endpoints = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      # THE single source of truth every client consumes as DATA (name -> url) and
      # the ONE place a gateway URL is constructed: `endpointFor` is invoked here
      # and nowhere else. desktop-commander is deliberately absent (stdio, claude-
      # code only). readOnly => the default IS the value (never reassigned).
      default = lib.genAttrs hostedServerNames (name: endpointFor name "mcp");
      description = ''
        Read-only map of hosted MCP server name -> its 127.0.0.1 Streamable-HTTP
        (/mcp) gateway URL. Populated once from `endpointFor`; consumed as data by
        every client (claude-code / VS Code / Claude Desktop), none of which
        re-derive a URL.
      '';
    };

    telegram.enable = lib.mkEnableOption ''
      the chaindead/telegram-mcp server in the gateway — MTProto USER-account access
      to your OWN Telegram (read/triage DMs + private groups + channels; DRAFT-only
      send, you press send). OFF by default because it needs BOTH the
      TG_APP_ID/TG_API_HASH pair in the login Keychain AND a one-time phone-code login
      creating ~/.telegram-mcp/session.json; the server refuses to start without a
      session, so enabling it before that is done would add a server that exits at
      startup. Turn ON only AFTER completing the auth (see the wrapper's steps).
      Reads your personal account — keep the agent to read-and-draft (ToS: spam-shaped
      automation risks the account)'';

    gmail.accounts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        PLAIN EMAIL ADDRESSES of Google/Workspace accounts to run as separate
        ArtyMcLabin/Gmail-MCP-Server processes (gmail-<sanitized-email>) —
        TRUE simultaneous multi-account Gmail, unlike the
        single-account-per-connection built-in connector (see mkGmailMcp's
        comment above; gmailAlias sanitizes each email into a tool-prefix/
        filename-safe token internally — this list itself stays plain
        emails). Empty by default and deliberately NOT populated in this
        public repo beyond the operator's own two already-public addresses
        (hosts/macos.nix): other accounts here are personal data, some
        belonging to people other than the operator, supplied instead by the
        PRIVATE nix-personal flake via `extraHomeModules` — the same
        composition contract as nixpi's `hostedSites`
        (docs/private-home-modules.md). All accounts share ONE Google Cloud
        OAuth Desktop-app client (GMAIL_OAUTH_CLIENT_ID/SECRET in the
        Keychain); each account ALSO needs its OWN completed one-time browser
        auth (~/.gmail-mcp/credentials-<sanitized-email>.json) BEFORE being
        added here — an account with no completed auth exits at startup,
        darkening that one gateway entry (not the whole gateway, since each
        is its own process).
      '';
    };

    localAdapter.enable = lib.mkEnableOption ''
      the LOCAL WordPress MCP Adapter server (the wp-env clone at http://localhost:8888)
      in the gateway. OFF by default: that endpoint only exists while the local clone is
      running, and mcp-proxy spawns every hosted server at startup, so wiring an
      unreachable endpoint risks a server that fails at launch. The PROD adapter
      (wordpress-adapter) is always on; enable this only while working against the local
      clone'';

  };

  config = lib.mkIf cfg.enable {
    # ---- Server side: the mcp-proxy launchd user agent -------------------------
    launchd.agents.mcp-gateway = {
      enable = true;
      config = {
        ProgramArguments = [
          (lib.getExe' pkgs.mcp-proxy "mcp-proxy")
          # --log-level ERROR keeps the gateway log to real failures only, dropping
          # the routine INFO/WARNING chatter mcp-proxy emits per request.
          "--log-level"
          "ERROR"
          "--host"
          gatewayHost
          "--port"
          (toString gatewayPort)
          "--named-server-config"
          "${gatewayConfig}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables = {
          # npx/uvx children need Node/uv on PATH (mcp-proxy itself is absolute above);
          # mobile-mcp additionally needs `adb` (platform-tools) + the emulator binary.
          PATH =
            lib.makeBinPath [
              pkgs.nodejs
              pkgs.uv
            ]
            + ":${androidSdkHome}/platform-tools:${androidSdkHome}/emulator:/usr/bin:/bin";
          # mobile-mcp resolves adb via $ANDROID_HOME/platform-tools/adb.
          ANDROID_HOME = androidSdkHome;
        };
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcp-gateway.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcp-gateway.log";
      };
    };

    # ---- Client side A: Claude Code (home-manager module) ----------------------
    programs.claude-code.mcpServers = httpEntries // {
      # NOT hosted — a shell/RCE surface stays a per-client stdio server.
      desktop-commander = {
        type = "stdio";
        command = npx;
        args = [
          "-y"
          "@wonderwhy-er/desktop-commander@latest"
        ];
      };
    };

    # ---- Client side B: VS Code (home-manager-managed → pure declarative file) --
    # VS Code is managed here (programs.vscode in modules/shared/home.nix), so its
    # MCP config is just a Nix-written file at the user mcp.json (coexists with the
    # settings.json HM already writes there). VS Code speaks `type = "http"` natively,
    # so it connects to the SAME gateway processes — no extra server instances.
    # GATED on programs.vscode.enable: drop VS Code and this file is never written (no
    # stray Code/User/ dir). Read-only/Nix-managed: add servers to `hostedServerNames`.
    home.file = lib.mkIf config.programs.vscode.enable {
      "Library/Application Support/Code/User/mcp.json".text = vscodeMcpJson;
    };

    # ---- Client side C: Grok CLI (stateful ~/.grok/config.toml → grok owns the merge)
    # No `programs.grok` HM module and a stateful config.toml, so an activation script merges
    # ONLY the [mcp_servers] tables via grok's OWN CLI, which stays robust to grok's TOML schema
    # (the `enabled` flag, --scope, future keys) since grok, not us, renders it. USER scope (not
    # project) so the servers aren't blocked by grok's folder-trust gate. GATED on the grok binary
    # existing (~/.grok/bin/grok) — no grok installed, nothing runs and no stray files are created.
    # We do NOT lean on grok's [compat.claude] mcps=true scan
    # of ~/.claude.json: the claude-code module writes the gateway to a MANAGED plugin .mcp.json
    # (not ~/.claude.json), which grok does not read — so explicit wiring here is the single
    # source of truth. Reuses cfg.endpoints, so grok can never drift from the gateway.
    home.activation.grokMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      grok="${grokBin}"
      if [ ! -x "$grok" ]; then
        : # Grok CLI not installed — nothing to configure, no stray files.
      else
        # 1) Add/update every gateway endpoint (idempotent: `mcp add` = add-or-update).
        ${grokAddLines}
        # 2) Prune stale gateway entries we no longer manage. Only touch servers whose URL is
        #    under OUR loopback gateway prefix, so a user's own MCP servers are never removed;
        #    drop any such entry no longer present in cfg.endpoints.
        desired=" ${grokDesiredNames} "
        "$grok" mcp list 2>/dev/null | while IFS= read -r line; do
          name="''${line%%:*}"
          name="''${name#"''${name%%[![:space:]]*}"}"   # strip leading whitespace
          url="''${line#*: }"
          case "$url" in
            ${grokGatewayPrefix}*) ;;                     # a gateway entry we own
            *) continue ;;                                # foreign server — leave it
          esac
          case "$desired" in
            *" $name "*) ;;                               # still desired — keep
            *) "$grok" mcp remove --scope user "$name" >/dev/null 2>&1 || true ;;
          esac
        done
      fi
    '';

    # ---- macos-automator Accessibility (TCC) preflight — non-fatal nudge -------
    # The macos-automator server drives System Events UI scripting via
    # /usr/bin/osascript, which needs an Accessibility (TCC) grant. Nothing in the
    # gateway's launchd chain can raise the consent prompt, so the grant is a
    # one-time manual step (docs/mcp-gateway-accessibility-tcc.md). This probes it
    # and prints the exact fix ONLY when TCC has denied osascript assistive access;
    # it NEVER blocks activation. The match on the specific "assistive access"
    # denial string means a headless/as-root activation (where osascript fails with
    # a DIFFERENT error — no GUI session) stays silent, so this can't false-warn on
    # every rebuild. The grant survives rebuilds (a fixed system path, not a store
    # path), so this is a nudge until granted, then permanently silent.
    home.activation.macosAutomatorAccessibilityCheck = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if probe="$(/usr/bin/osascript -e 'tell application "System Events" to get name of first process' 2>&1)"; then
        : # osascript already has Accessibility — nothing to warn about.
      else
        case "$probe" in
          *"not allowed assistive access"*)
            echo "" >&2
            echo "  ⚠ MCP gateway: the macos-automator server needs Accessibility for /usr/bin/osascript." >&2
            echo "    UI-scripting MCP calls fail until you grant it (one-time; survives rebuilds):" >&2
            echo "      System Settings → Privacy & Security → Accessibility → +  →  ⇧⌘G  →  /usr/bin/osascript  → enable" >&2
            echo "    Verify:  osascript -e 'tell application \"System Events\" to get name of first process'" >&2
            echo "    Details: docs/mcp-gateway-accessibility-tcc.md" >&2
            ;;
          *) : ;; # headless/as-root/transient failure (different error) — don't nag.
        esac
      fi
    '';
  };
}
