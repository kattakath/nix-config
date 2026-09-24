# The fleet's MCP gateway (darwin / the Mac): one shared instance of every
# server, published through Cloudflare, reached by every client as ONE connector.
#
# NOT "private, localhost-only" any more. It was until 2026-09-22, and the rest
# of this header was rewritten with it — the bind address is still 127.0.0.1, but
# that is now the tunnel's on-host origin, not the client-facing surface.
#
# RELATED, AND NOT A RIVAL IMPLEMENTATION: github.com/kattakath/nix-mcp-gateway
# WAS a standalone public flake that also declared `local.mcpGateway` — ARCHIVED
# 2026-09-12 as an extraction candidate nix-config never adopted. Archived, not
# deleted (ADR-002 §7.8), so it stays public and readable. It was a THIN, GENERIC
# broker module; this file is the fleet's fully-wired ~20-server CONFIGURATION of
# the same idea, and nix-config never declared an input on it. One generic module,
# one concrete deployment — never two competing options. That repo's
# modules/mcp-gateway.nix carries a "WHAT THIS IS NOT" header saying so from its
# side; this note is the missing half. The archiving settles the question for good:
# this file is the fleet's ONLY `local.mcpGateway`, and there is no live rival
# implementation to reconcile with or migrate to.
#
# WHAT THIS DOES
# Instead of every MCP client (Claude Code, Claude Desktop) spawning its OWN
# stdio copy of each server per session, we run ONE shared instance of each
# server behind sparfenyuk/mcp-proxy — a launchd USER agent bound to 127.0.0.1,
# started at login (RunAtLoad) and kept alive: shared memory-graph state, one
# cache, no duplicate spawns, always up.
#
# `desktop-commander` — a shell/RCE surface — was kept off the gateway entirely
# until 2026-09-22 and is now hosted like everything else, by operator decision;
# its entry in customStdioServers records what that accepts. `open-design` left
# the fleet in the same change (the APP is still installed as a cask — only its
# stdio MCP server is gone; docs/open-design.md). There are no per-client stdio
# servers left: every server this file declares is on the proxy.
#
# CONSTRAINT (tracked for removal, not yet fixed — 2026-09-16): by default a
# launchd USER agent lives in the GUI-only `gui/<uid>` domain, which only
# exists while that uid has an active GUI login. This agent targets `loginName`
# (uid 501, ismail), so the gateway only runs while ismail owns the console
# session — a second account gets no gateway of its own, and neither gets one
# before first login. Upstream already ships the fix: `domain = "user"`
# (pinned home-manager modules/launchd/default.nix:21-27) bootstraps into
# `user/<uid>` with no GUI login required at all. Not applied here yet — it
# needs a live-tested activation before landing, same as the mkForce'd agents
# in hosts/macos.nix that exist to work around this identical limitation.
#
# SERVER SIDE (this box, 127.0.0.1:<publicMcpPort>)
#   `mcp-proxy --named-server-config <gatewayConfig>` hosts every server in
#   `hostedServerNames`, each reachable at /servers/<name>/mcp. That roster must
#   equal `config.fleet.publicMcpServers` in BOTH directions — 26 servers today,
#   including one `gmail-<alias>` process per Google/Workspace account (the roster
#   is in hosts/macos.nix; see mkGmailMcp). The equality is not a convention:
#   `checks.<system>.mcp-published-parity` fails the build on either mismatch,
#   because a hosted-but-unpublished server is invisible and a published-but-
#   unhosted one registers a dead upstream with Cloudflare.
#
#   `gatewayConfig` is rendered by mcp-servers-nix's `lib.mkConfig`, so the
#   packaged servers (context7/fetch/memory/sequential-thinking/nixos/terraform/
#   github) are PINNED store-path commands; the rest fall back to pinned npx/uvx
#   launchers (still a runtime fetch, but acceptable on the Mac where Node/uv
#   already live).
#
#   ONE PORT, not two. A second proxy on :8096 served local clients until
#   2026-09-22 — see gatewayPort below for why publishing every server killed
#   that split's only justification.
#
#   `telegram` is the one server in neither list: withdrawn from
#   publicMcpServers 2026-09-22 (it advertises `prompts`/`resources` then answers
#   -32000 on both, which darks portal discovery) AND left off the gateway by its
#   `local.mcpGateway.telegram.enable = false` default. Those two facts are now
#   COUPLED — see that option for what enabling it costs.
#
# CLIENT SIDE — every client gets ONE connector, not a server list.
#   Clients do not address this box at all. They dial the portal
#   (`portalUrl`, https://mcp.<domainName>/mcp), which Cloudflare Access
#   authenticates against Workspace and proxies back in through the tunnel to the
#   port above. So the client config is a single entry regardless of how many
#   servers exist, and every call carries an identity instead of being trusted
#   for running on this machine.
#
#   That one entry is declared ONCE, in `hubServers`, and rendered per client by
#   home-manager's `programs.mcp` hub: Claude Code via
#   `programs.claude-code.enableMcpIntegration`, VS Code via its own
#   `enableMcpIntegration`. Claude Desktop needs a renderer the hub does not
#   ship, so ./claude-desktop.nix wraps the same portal URL in an mcp-remote
#   stdio shim (Desktop's schema takes no `url`) — docs/claude-desktop-mcp.md.
#
# SCOPE: darwin only (the Mac is the sole MCP client host; keeps the Pi/VM lean).
# There is no project ./.mcp.json — this user-scope gateway is the single source.
{
  pkgs,
  lib,
  config,
  mcp-servers-nix,
  # The Nix-agnostic MCP client-config catalog this file generates
  # `packagedPrograms`/`customStdioServers` from — kattakath/skills'
  # `mcp-clients/catalog.mcp.json`, not this repo's. See `mcpCatalog` below.
  kattakath-skills,
  # THE published-gateway port, from modules/parts/identity.nix via
  # extraSpecialArgs. Not a literal here: infra/cloudflare/mcp-public.nix routes
  # the tunnel's ingress at the same number and cannot see this file.
  publicMcpPort,
  # The zone the portal lives on, from the same identityArgs thread. Needed here
  # since 2026-09-22: clients address `mcp.<domainName>` rather than loopback.
  domainName,
  ...
}:
let
  cfg = config.local.mcpGateway;

  # THE gateway endpoint. Loopback-bound: the cloudflared connector reaches it
  # from on-host, and nothing else can. Clients do NOT talk to this — they go out
  # to the portal and back in through the tunnel, so every call carries a
  # Workspace identity rather than being trusted for running on this machine.
  gatewayHost = "127.0.0.1";
  # ONE proxy, on the port the tunnel's ingress already targets.
  #
  # There were TWO until 2026-09-22 — a private :8096 for local clients and a
  # published :8097 — because Access protects a HOSTNAME, not a path, so tunnelling
  # the private one would have exposed every server to a leaked service token.
  # That argument was load-bearing while 2 of 26 servers were published. Publishing
  # ALL of them killed it: both processes hosted the same set, so the split bounded
  # nothing but a crash while costing a duplicate instance of every server —
  # measured at 50 processes for 25 servers, two copies of each fighting over one
  # Gmail credential file, one MTProto session and one memory graph.
  gatewayPort = publicMcpPort;

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

  # ---- The per-server CATALOG (Nix-agnostic; lives at kattakath/skills'
  # mcp-clients/catalog.mcp.json, PINNED via the kattakath-skills flake input like
  # superhook/page-lab-pick — a merge there ships nothing here until this repo's
  # own pin is bumped, same as those two) ----------------------------------------
  #
  # WHAT'S IN IT, AND WHY IT'S SHAPED THIS WAY: every entry is the STANDARD
  # `.mcp.json`/`claude_desktop_config.json` `mcpServers` shape — literally what
  # each server's own README shows under "add this to your client." `env` values
  # are `${VAR_NAME}` PLACEHOLDERS, never real values and never a
  # Keychain/passwordCommand hint — the whole point of the public repo this will
  # live in is that one entry pastes into ANYONE's own client config with zero
  # knowledge nix-config exists. A `type: "http"`/`"sse"` entry (cloudflare,
  # cloudflare-docs) names a remote server with no local command at all — the
  # schema upstream already has for that.
  #
  # WHAT'S DELIBERATELY NOT IN IT: nix-config's OWN fleet-specific hardening —
  # version/interpreter pins that guard against a runtime `npx`/`uvx` fetch
  # drifting onto a broken release (postgres, arxiv, mcpfinder, wordpress,
  # mcp-jq), and the nixpkgs package-attr overrides that repair a framework
  # default that fails to build on this pin (fetch/memory/sequential-thinking/
  # nixos). Those stay in `catalogArgOverrides`/`packagedProgramOverrides` below,
  # entirely inside nix-config — a portable catalog has no business carrying a
  # THIS-FLEET nixpkgs revision's build repair. Nor is the Keychain/agenix fetch
  # mechanism in it anywhere: `requiredEnvToPasswordCommand` below is nix-config's
  # own separate, non-portable mapping from an env-var NAME the catalog names to
  # the actual `security find-generic-password` invocation that fills it.
  #
  # Four `gmail-<account>` published names collapse to ONE `gmail` template here
  # (see the fan-out at `gmailMcps`/`hostedServerNames` below — unchanged from
  # before this refactor) — extraction-notes.md has the full per-server reasoning
  # for every judgment call in this file.
  mcpCatalog =
    (builtins.fromJSON (builtins.readFile "${kattakath-skills}/mcp-clients/catalog.mcp.json")).mcpServers;

  # nix-config's OWN mapping from an env-var NAME (as the catalog names it in a
  # server's `env` block) to the exact Keychain invocation that fills it TODAY —
  # read out of the pre-catalog file's hand-typed wrappers/passwordCommands, not
  # invented. This table, and this table alone, is what may never leave
  # nix-config for the public catalog repo (§ Security: no secret-fetch detail in
  # a public file). `DATABASE_URI` is the one entry that ISN'T a Keychain
  # command — postgres's connection string is a loopback-trust, no-secret value
  # from another fleet-internal option, so it is special-cased directly in
  # `mkGeneratedStdio` below rather than living in this table.
  requiredEnvToPasswordCommand = {
    CONTEXT7_API_KEY = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "CONTEXT7_API_KEY"
      "-w"
    ];
    GITHUB_PERSONAL_ACCESS_TOKEN = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "gh:github.com:pat"
      "-w"
    ];
    APIFY_TOKEN = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "mcp:apify.com:token"
      "-w"
    ];
    WORDPRESS_SITE_URL = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "mcp:silvercreek.ai:wp_url"
      "-w"
    ];
    WORDPRESS_USERNAME = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "mcp:silvercreek.ai:wp_user"
      "-w"
    ];
    WORDPRESS_APP_PASSWORD = [
      "/usr/bin/security"
      "find-generic-password"
      "-a"
      "$(id -un)"
      "-s"
      "mcp:silvercreek.ai:wp_app_password"
      "-w"
    ];
  };

  # The 7 mcp-servers-nix `programs.<name>` modules this fleet uses — one source
  # for both the catalog lookup key and the generated `packagedPrograms` attrset.
  packagedProgramNames = [
    "context7"
    "fetch"
    "memory"
    "sequential-thinking"
    "nixos"
    "terraform"
    "github"
  ];

  # Fleet-specific nixpkgs package-attr overrides for a packaged program whose
  # FRAMEWORK DEFAULT fails to build/run on this pin — never derivable from the
  # (Nix-agnostic) catalog, which names only the upstream package, not a nixpkgs
  # attr in THIS flake's revision. Read out of the pre-catalog file; see
  # extraction-notes.md "Packaged servers" for the why on each.
  packagedProgramOverrides = {
    fetch.package = pkgs.mcp-server-fetch;
    memory.package = pkgs.mcp-server-memory;
    sequential-thinking.package = pkgs.mcp-server-sequential-thinking;
    nixos.package = pkgs.mcp-nixos.overrideAttrs (_: {
      doCheck = false;
      doInstallCheck = false;
    });
  };

  mkPackagedProgram =
    name:
    let
      entry = mcpCatalog.${name};
      envNames = builtins.attrNames (entry.env or { });
    in
    {
      enable = true;
    }
    // (packagedProgramOverrides.${name} or { })
    // lib.optionalAttrs (envNames != [ ]) {
      passwordCommand = lib.genAttrs envNames (v: requiredEnvToPasswordCommand.${v});
    };

  # Resolves the catalog's PORTABLE command name ("npx"/"uvx" — every plain stdio
  # entry in this catalog uses one of the two) to this fleet's pinned store-path
  # executable.
  resolveCatalogCommand =
    name:
    if name == "npx" then
      npx
    else if name == "uvx" then
      uvx
    else
      throw "kattakath-skills's mcp-clients/catalog.mcp.json: unrecognised command '${name}' for a generated stdio server (only npx/uvx are resolved here — anything else needs a hand-written entry in customStdioServers, same as wordpress-adapter/chrome-devtools/gmail)";

  # Fleet-specific ARG overrides for a handful of generated stdio servers: the
  # catalog carries the PORTABLE/basic invocation (what a README paste would
  # give you), and these are the drift-guard version/interpreter pins this fleet
  # needs on top, because mcp-proxy spawns every server sequentially at startup
  # and ONE that fails to install/import darks the WHOLE gateway (see the
  # detailed measurements this used to carry inline, preserved here):
  #
  #   postgres: `--python 3.12` steers uv away from a CPython whose wheels
  #     pglast/postgres-mcp's deps lag; `--with mcp<2 --from postgres-mcp==0.3.0`
  #     pins around mcp 2.0 removing the vendored `fastmcp` that 0.3.0 still
  #     imports (mcp 2.0 => import crash => gateway dark).
  #   arxiv: same `--python 3.12` reasoning (aiohttp/pydantic-core/lxml wheels),
  #     `arxiv-mcp-server==0.7.2` pins the release, and `--storage-path` moves
  #     downloaded papers off the default ~/.arxiv-mcp-server dotdir to XDG data.
  #   mcpfinder: `@1.1.0` is pinned because a later release could reintroduce the
  #     `add_mcp_server_config` write-tool this gateway deny-lists elsewhere.
  #   wordpress: `@3.3.30` pins the client library version.
  #   mcp-jq: this fleet's args OMIT the catalog's own README `-y` (kept for
  #     behavioural parity with the pre-catalog file, not because `-y` is wrong).
  catalogArgOverrides = {
    mcp-jq = [ "@247arjun/mcp-jq" ];
    mcpfinder = [
      "-y"
      "@mcpfinder/server@1.1.0"
    ];
    postgres = [
      "--python"
      "3.12"
      "--with"
      "mcp<2"
      "--from"
      "postgres-mcp==0.3.0"
      "postgres-mcp"
      "--access-mode=unrestricted"
    ];
    arxiv = [
      "--python"
      "3.12"
      "--from"
      "arxiv-mcp-server==0.7.2"
      "arxiv-mcp-server"
      "--storage-path"
      "${config.xdg.dataHome}/arxiv-mcp-server/papers"
    ];
    wordpress = [
      "-y"
      "mcp-wordpress@3.3.30"
    ];
  };

  # Catalog names this fleet generates mechanically into `customStdioServers` —
  # a plain command/args pass-through, with any `env` names wired to a Keychain
  # fetch generically (mirroring mcp-servers-nix's OWN `mkServerModule` wrapper
  # shape for `passwordCommand` — `settings.servers` raw entries have no
  # equivalent of that, which is WHY this fleet grew hand-rolled Keychain
  # wrappers per server in the first place; this one function replaces every one
  # of them that was doing nothing more than "export a var, then exec").
  #
  # NOT in this list, and never generated: `cloudflare`/`cloudflare-docs` (the
  # catalog names them remote `type: "http"` servers; this fleet still bridges
  # both through `mcp-remote` for OAuth reasons a generic generator can't
  # express), `wordpress-adapter` (derives a Basic-auth header, not a raw
  # secret), `chrome-devtools` (dual-mode port-probing at spawn time), and
  # `gmail` (materializes a credentials file per account). All four stay
  # hand-written below — see extraction-notes.md for the why on each.
  generatedStdioNames = [
    "desktop-commander"
    "kapture"
    "duckduckgo"
    "json-yaml-toml"
    "macos-automator"
    "mobile-mcp"
    "apify"
    "wordpress"
    "mcp-jq"
    "mcpfinder"
    "postgres"
    "arxiv"
  ];

  mkGeneratedStdio =
    name:
    let
      entry = mcpCatalog.${name};
      cmd = resolveCatalogCommand entry.command;
      args = catalogArgOverrides.${name} or entry.args or [ ];
      envNames = builtins.attrNames (entry.env or { });
    in
    if envNames == [ ] then
      {
        command = cmd;
        inherit args;
      }
    else if envNames == [ "DATABASE_URI" ] then
      # Not a Keychain secret — see requiredEnvToPasswordCommand's header.
      {
        command = cmd;
        inherit args;
        env.DATABASE_URI = config.local.rag.pgvector.databaseUri;
      }
    else
      let
        wrapper = pkgs.writeShellScriptBin "nix-mcp-${name}" ''
          set -u
          ${lib.concatMapStringsSep "\n" (v: ''
            export ${v}="$(${toString requiredEnvToPasswordCommand.${v}} 2>/dev/null || true)"
            if [ -z "${"$" + v}" ]; then
              echo "${name}: missing ${v} in the login Keychain — tools will fail until set." >&2
            fi
          '') envNames}
          export HOME="${config.home.homeDirectory}"
          exec ${cmd} ${lib.concatMapStringsSep " " lib.escapeShellArg args}
        '';
      in
      {
        command = lib.getExe wrapper;
        args = [ ];
      };

  generatedStdioServers = lib.genAttrs generatedStdioNames mkGeneratedStdio;

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
  # (local.mcpGateway.telegram.enable) and must be enabled only AFTER the one-time
  # auth below — a server that exits at startup could dark the whole gateway. Basename
  # nix-* for the BTM origin rule. Store the pair + auth once:
  #     secret set TG_APP_ID <app_id> ; secret set TG_API_HASH <api_hash>
  #     npx -y @chaindead/telegram-mcp auth --app-id <id> --api-hash <hash> --phone +<number>
  telegramMcp = pkgs.writeShellScriptBin "nix-telegram-mcp" ''
    set -eu
    app_id="$(/usr/bin/security find-generic-password -a "$(id -un)" -s mcp:telegram.org:app_id -w 2>/dev/null || true)"
    api_hash="$(/usr/bin/security find-generic-password -a "$(id -un)" -s mcp:telegram.org:api_hash -w 2>/dev/null || true)"
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
  # telegramMcp above). Each account gets its OWN GMAIL_CREDENTIALS_PATH —
  # populated by a SEPARATE one-time interactive `auth` run per account (opens a
  # browser; the tool itself writes that file, this wrapper never touches it).
  #
  # WHICH accounts run is cfg.gmail.accounts, empty by default here — the real
  # list is set in `hosts/macos.nix`, and holds ONLY the operator's own
  # accounts, each under an identity already public in this tree. Anyone
  # else's address never goes there. (The private nix-personal flake used to
  # add further accounts; it was fully retired 2026-09-15 and only two of its
  # seven were carried over — #524.) An account with no completed auth exits
  # at startup, so only add an email AFTER its one-time browser login is done.
  # Basename nix-* for the BTM origin rule.
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
  # comment for why the list is set per host rather than defaulted here).
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
  # argv. GENERATED now (mkGeneratedStdio, from the "wordpress" catalog entry's
  # `env` names + `requiredEnvToPasswordCommand` above) rather than a bespoke
  # wrapper — was `wpMcp`, which did nothing a generic export-then-exec wrapper
  # doesn't. Store the three once:
  #     secret set WP_URL <https://www.SITE>   # MUST be the canonical www host —
  #       a non-www host that 301-redirects cross-host DROPS the Authorization
  #       header, so REST auth 401s. secret set WP_ADMIN_USER <login> ;
  #     secret set WP_ADMIN_APP_PASSWORD <app-pw>   # wp-admin ▸ Users ▸ Profile ▸
  #       Application Passwords — NOT the login password (WP refuses it for REST).
  # Resilient by design: on a missing secret the generated wrapper warns but
  # STILL execs (same as before), so an absent secret can't dark the shared
  # gateway (unlike telegram, which exits).
  # chrome-devtools-mcp, with the attach flag chosen AT SPAWN TIME.
  #
  # WHY A WRAPPER, when the motto says reach for the option first: measured
  # 2026-09-07, NO single upstream flag attaches in both of the modes a browser can
  # be in, because the two discovery sources fail in opposite conditions.
  #
  #   mode                          /json/*   DevToolsActivePort   works
  #   chrome://inspect consent      404       fresh                --autoConnect
  #   --remote-debugging-port       200       STALE                --browser-url
  #
  # The staleness is not theoretical: Opera Air relaunched with the flag left the
  # file untouched for over two hours, and its line-2 UUID was DEAD while
  # /json/version served a live one [F-DEVTOOLSACTIVEPORT-STALE]. So --autoConnect,
  # which trusts that file, fails against a launch-flag browser; and --browser-url,
  # which needs /json/version, fails against a consent-mode one [F-NO-JSON-HTTP].
  #
  # Order is the whole point: /json/version is AUTHORITATIVE when it answers, because
  # it carries the live webSocketDebuggerUrl rather than a cached copy of it. Only
  # when nothing answers do we fall back to the file — which is exactly the mode in
  # which the file is fresh.
  #
  # Known limit, stated rather than hidden: the probe runs ONCE, when mcp-proxy spawns
  # this at startup. A browser that changes mode afterwards is not re-detected until
  # the gateway restarts. The fallback is the lazy one, so an absent browser still
  # does not dark the gateway [F-MCP-SURVIVES-CLOSED-PORT].
  chromeDevtoolsMcp = pkgs.writeShellScriptBin "nix-mcp-chrome-devtools" ''
    set -eu
    dir="${cfg.chromeDevtools.userDataDir}"
    active="$dir/DevToolsActivePort"

    # The pinned port first, then whatever the browser recorded for itself. Line 1 of
    # DevToolsActivePort is trustworthy even when line 2 is not — the port is what the
    # browser bound, the UUID is a cached copy that Opera does not always refresh.
    ports="${toString cfg.chromeDevtools.port}"
    if [ -r "$active" ]; then
      recorded="$(sed -n 1p "$active" 2>/dev/null | tr -d "[:space:]")"
      case "$recorded" in
        ''' | *[!0-9]*) ;;
        "${toString cfg.chromeDevtools.port}") ;;
        *) ports="$ports $recorded" ;;
      esac
    fi

    for p in $ports; do
      if /usr/bin/curl -fsS --max-time 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
        exec ${npx} -y chrome-devtools-mcp@latest \
          --browser-url="http://127.0.0.1:$p" \
          --no-usage-statistics --no-performance-crux
      fi
    done

    exec ${npx} -y chrome-devtools-mcp@latest \
      --autoConnect --userDataDir="$dir" \
      --no-usage-statistics --no-performance-crux
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
      user="$(/usr/bin/security find-generic-password -a "$(id -un)" -s mcp:silvercreek.ai:wp_user -w 2>/dev/null || true)"
      pass="$(/usr/bin/security find-generic-password -a "$(id -un)" -s mcp:silvercreek.ai:wp_app_password -w 2>/dev/null || true)"
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
  # used until 2026-08-19. That OAuth flow needs an interactive browser
  # redirect on first use, which a headless launchd agent can never complete;
  # confirmed stuck in mcp-gateway.log re-issuing a fresh PKCE challenge on
  # every connection attempt with no way to finish it. GENERATED now
  # (mkGeneratedStdio, from the "apify" catalog entry's `env` names +
  # requiredEnvToPasswordCommand above) — was `apifyMcp`, a bespoke wrapper
  # doing nothing a generic export-then-exec wrapper doesn't. Store the token
  # once:
  #     secret set APIFY_TOKEN <token>   # Apify Console → Settings → Integrations

  # The servers with no mcp-servers-nix module, as raw stdio commands. Merged into
  # the gateway config via mkConfig's `settings.servers` (telegram appended below,
  # opt-in). Most are GENERATED from kattakath-skills's mcp-clients/catalog.mcp.json (mkGeneratedStdio) —
  # a plain pinned npx/uvx launcher, with any Keychain secret wired through
  # requiredEnvToPasswordCommand where the catalog names one. wordpress-adapter and
  # chrome-devtools stay hand-written wrappers below (see their own comments for
  # why); gmail's per-account fan-out lives further down.
  # cloudflared connector for the PUBLISHED gateway. arg0 is a nix-* wrapper per
  # .claude/rules/launchd-naming.md (launchd-launcher.nix would rename it anyway,
  # but the token read has to happen somewhere and a wrapper is that somewhere).
  #
  # The connector token is read from the login Keychain AT LAUNCH, so it is never
  # in argv, never in the /nix/store, and never in this file — the same
  # passwordCommand shape context7/github use. Store it after the terranix apply
  # prints it:  secret set cf:cloudflare.com:mcp-connector
  mcpTunnelConnector = pkgs.writeShellScriptBin "nix-mcp-tunnel-connector" ''
    set -euo pipefail
    TUNNEL_TOKEN="$(/usr/bin/security find-generic-password -a "$(id -un)" \
      -s cf:cloudflare.com:mcp-connector -w 2>/dev/null || true)"
    if [ -z "$TUNNEL_TOKEN" ]; then
      echo "nix-mcp-tunnel-connector: no token in the login Keychain under" >&2
      echo "  cf:cloudflare.com:mcp-connector" >&2
      echo "Run the terranix apply for infra/cloudflare/mcp-public.nix, then:" >&2
      echo "  secret set cf:cloudflare.com:mcp-connector" >&2
      exit 1
    fi
    export TUNNEL_TOKEN
    exec ${lib.getExe pkgs.cloudflared} --no-autoupdate tunnel run
  '';

  # The servers with no mcp-servers-nix module, as raw stdio commands, merged
  # into the gateway config via mkConfig's `settings.servers` (telegram appended
  # below, opt-in). `generatedStdioServers` (mkGeneratedStdio, above) supplies
  # 12 of these mechanically from kattakath-skills's mcp-clients/catalog.mcp.json:
  #
  #   desktop-commander — SHELL/RCE SURFACE, on the gateway and published — an
  #     operator decision taken 2026-09-22 with the consequence stated rather
  #     than implied: anything holding a valid Workspace session for this
  #     domain can drive a shell on this Mac through it. It was excluded from
  #     the gateway until then, and two assertions used to make that
  #     structural — what changed is not the risk, it is the architecture:
  #     with every server published, the private/published split bounded
  #     nothing, so keeping ONE server off the proxy bought a second
  #     transport and a second process tree for no isolation. The gate that
  #     matters is Access + Workspace OAuth restricted to the domain, the same
  #     gate every other server is behind.
  #   kapture — the SERVER half of Kapture (modules/shared/chromium.nix owns
  #     the extension, `local.chromium.kaptureMcp`). `bridge` is the
  #     subcommand, not a flag — kapture-mcp exposes the local websocket
  #     bridge the extension connects back to; a running bridge with ZERO
  #     connected tabs is DARK, not ready, since a tab is only visible after
  #     the operator toggles it from the extension's toolbar popup.
  #   duckduckgo, json-yaml-toml — no credentials, no fleet-specific pins.
  #   arxiv — blazickjp/arxiv-mcp-server (Apache-2.0): search, abstracts,
  #     section-level LaTeX reads, BibTeX export, citation graphs and on-disk
  #     topic watches. No credentials; version/interpreter pins and the
  #     storage-path override live in `catalogArgOverrides` above.
  #   mcp-jq — no credentials; see `catalogArgOverrides` for the one arg
  #     difference from the catalog's own README form.
  #   mcpfinder — MCP-server DISCOVERY (mcpfinder.dev — @mcpfinder/server,
  #     AGPL-3.0): cross-registry search over the Official MCP Registry +
  #     Glama + Smithery via `search_mcp_servers`/`get_server_details`. Wired
  #     DISCOVERY-ONLY: it registers FOUR read-only tools (verified from a
  #     live session's namespace 2026-09-16); a fifth, `add_mcp_server_config`
  #     (writes client config files imperatively — the exact anti-pattern this
  #     gateway exists to avoid), is deny-listed in nix-config's
  #     `.claude/settings.json` and again user-scope in
  #     `modules/shared/claude-guardrails.nix`. Version pin lives in
  #     `catalogArgOverrides` for exactly that reason: don't let a future
  #     release reintroduce that tool silently.
  #   macos-automator — native macOS automation via osascript
  #     (steipete/macos-automator-mcp, 854★). A POWERFUL surface
  #     (`execute_script` can `do shell script` and drive any app) but
  #     localhost-only like the rest of the gateway, and shared across clients
  #     by request. Needs a ONE-TIME Accessibility (TCC) grant for
  #     /usr/bin/osascript — see `home.activation.macosAutomatorAccessibilityCheck`
  #     below and docs/mcp-gateway-accessibility-tcc.md.
  #   mobile-mcp — cross-platform mobile automation over ADB (mobile-next/mobile-mcp,
  #     5.5k★). Needs `adb` + the Android SDK on PATH — the gateway agent below
  #     adds ${androidSdkHome}/platform-tools and exports ANDROID_HOME.
  #   apify — Apify Store's Actors as tools (search/run/dataset access), run
  #     LOCALLY via APIFY_TOKEN — NOT the hosted mcp.apify.com OAuth bridge
  #     used until 2026-08-19 (that flow needs an interactive browser redirect
  #     a headless launchd agent can never complete).
  #   postgres — local Postgres + pgvector for vector-similarity/RAG work.
  #     crystaldba's `postgres-mcp` ("Postgres MCP Pro") — a general SQL
  #     executor, so every pgvector op is just SQL it can run. (The official
  #     @modelcontextprotocol/server-postgres is ARCHIVED with an unpatched
  #     read-only-bypass SQL-injection CVE — deliberately avoided.)
  #     `--access-mode=unrestricted` lets it create tables + insert/query
  #     vectors; the blast radius is bounded not by that flag but by
  #     DATABASE_URI's role `mcp`, which owns ONLY `ragdb` and connects
  #     loopback-trust with no secret (see mkGeneratedStdio's DATABASE_URI
  #     special case above). THIS LINE IS THE CAREER RAG's whole path to
  #     Claude Code. Version/interpreter pins live in `catalogArgOverrides`
  #     for the two ways an unbounded `uvx postgres-mcp` was measured to go
  #     dark — see that table's header for the detail.
  #   wordpress — WordPress admin for the live site over its REST API
  #     (docdyhr/mcp-wordpress, ~59 tools).
  #
  # cloudflare/cloudflare-docs, wordpress-adapter, and chrome-devtools (opt-in,
  # below) stay hand-written — see kattakath-skills's mcp-clients/catalog.mcp.json's header comment
  # and extraction-notes.md for why each isn't generated.
  customStdioServers =
    generatedStdioServers
    // {
      # The catalog names both of these remote `type: "http"` servers — see
      # generatedStdioNames' comment above for why this fleet still bridges
      # through `mcp-remote` rather than a native remote dial.
      cloudflare-docs = {
        command = npx;
        args = [
          "-y"
          "mcp-remote"
          mcpCatalog.cloudflare-docs.url
        ];
      };
      cloudflare = {
        command = npx;
        args = [
          "-y"
          "mcp-remote"
          mcpCatalog.cloudflare.url
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
    #
    # ENABLING IT NOW FAILS `nix flake check`, and that is deliberate rather than a
    # bug to route around. It joins `hostedServerNames` but is absent from
    # `config.fleet.publicMcpServers` (withdrawn 2026-09-22, identity.nix has the
    # measurement), so `checks.<system>.mcp-published-parity` reports "hosted but
    # NOT published". Before 2026-09-22 that combination was the NORMAL state — a
    # server could be hosted privately and simply not published. With one proxy and
    # one portal there is no private half to hold it, so the parity check is right
    # and the honest options are both edits, not overrides: re-publish it (only once
    # the upstream -32000 is fixed, or the portal registration errors again), or
    # leave this off.
    // lib.optionalAttrs cfg.telegram.enable {
      telegram = {
        command = lib.getExe telegramMcp;
        args = [ ];
      };
    }
    # Opt-in (default off): Google's Chrome DevTools Protocol server, in ATTACH mode
    # against a browser that already has remote debugging on. Companion to the
    # in-repo `page-lab` plugin, which carries the measured behaviour.
    #
    # ATTACH FLAG CHOSEN AT SPAWN TIME by `nix-mcp-chrome-devtools` above, because
    # neither upstream flag works in both browser modes — see that wrapper's header for
    # the measured table. Short version: consent-mode browsers 404 every /json/* path so
    # `--browser-url` cannot attach [F-NO-JSON-HTTP], and launch-flag browsers leave a
    # STALE DevToolsActivePort so `--autoConnect` attaches to a dead WebSocket
    # [F-DEVTOOLSACTIVEPORT-STALE]. The wrapper probes /json/version first and only falls
    # back to the file when nothing answers, which is precisely when the file is fresh.
    #
    # WHY OFF BY DEFAULT, and why attach rather than launch:
    #  - mcp-proxy spawns every hosted server at startup. In attach mode this one
    #    needs a browser with debugging already on; with none it is a server that
    #    cannot work, exactly like localAdapter above.
    #  - Enabling it is a SECURITY DECISION, not a convenience one. Upstream's own
    #    warning about that port: "Any application on your machine can connect."
    #    Anything local can then read page content, cookies and session state and
    #    act as the signed-in user — and this Mac's browser carries the Apple
    #    Passwords native host and live sessions. `nix-chromium-debug` therefore
    #    exists as a deliberate, temporary act, not a login item.
    #
    # Telemetry is ON by default upstream; both flags below turn it off. The CrUX
    # one is the load-bearing half — without it, performance tools send the URLs
    # being traced to Google.
    #
    # Not pinned to a version: `@latest` is upstream's own documented invocation and
    # the tool surface is still moving (1.8.0 ships 29 of the ~57 tools its docs
    # describe — measured 2026-09-06). A pin here would freeze a set that is
    # actively growing; the plugin's references/tools.md says how to re-measure.
    // lib.optionalAttrs cfg.chromeDevtools.enable {
      chrome-devtools = {
        command = lib.getExe chromeDevtoolsMcp;
        args = [ ];
      };
    }
    # TRUE simultaneous multi-account Gmail — one server process PER configured
    # email (see mkGmailMcp above for why, and why the list is set in
    # hosts/macos.nix rather than here). Empty cfg.gmail.accounts (the
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

  # Every server NAME the gateway hosts (7 packaged + 14 base custom, plus
  # opt-ins — 26 today: the 21 fixed ones, chrome-devtools, and four gmail).
  # Single source for the client SSE URLs, so the two sides can never drift.
  # Order/names MUST
  # match the packaged servers enabled in `gatewayConfig.programs` below.
  hostedServerNames = packagedProgramNames ++ builtins.attrNames customStdioServers;

  # SERVER SIDE: a {mcpServers:{name:{command,args,env}}} JSON that mcp-proxy
  # consumes via --named-server-config. mkConfig PINS the 7 packaged servers;
  # settings.servers carries customStdioServers verbatim — 14 base plus whatever
  # the opt-ins add, so 19 as this host is configured. flavor "claude-code"
  # emits the `mcpServers` key mcp-proxy expects (it ignores any extra fields).
  # The packaged servers' definitions are GENERATED (mkPackagedProgram, above)
  # from kattakath-skills's mcp-clients/catalog.mcp.json's `env` names + `packagedProgramOverrides` —
  # named ONCE so the private gateway and the published one cannot diverge.
  # They did before this existed: the published config used to rebuild this
  # attrset as a bare `enable = true` per name, which silently dropped every
  # `package`/`passwordCommand` the real definition carries. That is how the
  # 2026-09-14 memory/sequential-thinking breakage survived being fixed - the
  # fix landed here, the public gateway kept building the broken framework
  # default, and nothing but a real activation could tell. Per-server detail:
  #
  #   context7 — an API key raises rate limits; fetched at gateway LAUNCH from
  #     the login Keychain by the passwordCommand wrapper mcp-servers-nix
  #     itself generates (`export CONTEXT7_API_KEY=$(security …)` then execs
  #     context7-mcp) — never in argv or the store. An absent key => empty
  #     export => runs unauthenticated exactly as before.
  #   fetch/memory/sequential-thinking — the FRAMEWORK DEFAULT package for each
  #     fails to build/run on this pin (httpx `proxies=` kwarg removed for
  #     fetch; a tsc `Cannot find name 'process'` break for the other two,
  #     which took the whole darwin-system down on 2026-09-14) — this flake's
  #     top-level nixpkgs ships fixed builds instead (`packagedProgramOverrides`
  #     above). Verified by REALISING each override, not a green build line —
  #     `nix build --print-out-paths` happily prints the output path of a
  #     derivation it has only planned.
  #   nixos — grounded, READ-ONLY nixpkgs/NixOS/Home-Manager/nix-darwin
  #     option+package lookup (utensils/mcp-nixos); this repo authors config
  #     for exactly those three surfaces every session. No token.
  #     mcp-nixos 2.4.3's `test_read_text_file` is brittle on aarch64-darwin
  #     (asserts a sampled /nix/store text file has no "Error" substring — a
  #     false positive, unrelated to the server), so doCheck is disabled just
  #     to let it build.
  #   terraform — Terraform Registry provider/module/policy schema docs
  #     (hashicorp/terraform-mcp-server) for the terranix → Cloudflare IaC
  #     under infra/. Registry-docs only (no HCP/TFE token supplied) =>
  #     read-only.
  #   github — GitHub's official MCP server (typed PR/CI/issue/code-search
  #     tools) — more reliable than scraping `gh` output for the one-PR-per-
  #     session + GitHub-hosted-CI flow. The PAT is fetched at gateway LAUNCH
  #     from the login Keychain via passwordCommand, never in argv or the
  #     store. An absent key => empty export => the server starts but its
  #     calls fail auth until a token is present (degrades, not crashes).
  packagedPrograms = lib.genAttrs packagedProgramNames mkPackagedProgram;

  gatewayConfig = mcp-servers-nix.lib.mkConfig pkgs {
    flavor = "claude-code";
    fileName = "mcp-gateway.json";
    programs = packagedPrograms;
    settings.servers = customStdioServers;
  };

  # THE client URL, and there is only one. Clients no longer address a server
  # each on loopback; they address the PORTAL, which fronts every published
  # server behind one Workspace-authenticated door.
  #
  # `mcp.<domain>` is Cloudflare-operated and cannot be pointed at the tunnel —
  # it dials `upstream.<domain>` with a service token, which is what reaches the
  # proxy here. Two hostnames, and the count does not grow per server.
  portalUrl = "https://mcp.${domainName}/mcp";

  # One entry, consumed as data by every client module. The attribute NAME is
  # what a client shows the user, so it names the portal rather than a server.
  hubServers.kattakath-portal.url = cfg.portalEndpoint;

in
{
  options.local.mcpGateway = {
    enable =
      lib.mkEnableOption "the localhost MCP gateway (a sparfenyuk mcp-proxy launchd user agent hosting the shared packaged + custom MCP servers on 127.0.0.1)"
      // {
        # The Mac is the sole MCP client host; inert (nothing emitted) on the Pi/VM.
        # Reproduces today's `lib.mkIf pkgs.stdenv.hostPlatform.isDarwin` gate exactly.
        default = pkgs.stdenv.hostPlatform.isDarwin;
      };

    portalEndpoint = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      internal = true;
      default = portalUrl;
      description = ''
        THE client URL, and the only one. Every client — Claude Code, Claude
        Desktop — points here; neither addresses a
        server directly any more.

        Was an attrset of 26 loopback URLs until 2026-09-22. Collapsing it to one
        is what removed the second proxy, the duplicate process per server, and
        the class of bug where a newly hosted server was silently not published.
      '';
    };

    hostedServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = hostedServerNames;
      description = ''
        Every server this proxy hosts. Read by `checks.<system>.mcp-published-parity`
        to assert it equals `config.fleet.publicMcpServers` — terranix renders
        outside any host's module system and cannot read this back, so the two
        lists are kept honest by a check rather than by convention.

        There is no `public` option any more. It listed which of the hosted
        servers to ALSO run on a second proxy; with one proxy and everything
        published, a subset is not expressible and was not wanted.
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
        emails). Empty by default; hosts/macos.nix sets the operator's own
        accounts, each under an identity already public in this tree. Never
        list anyone else's address here: it is personal data in a public
        repo. (The private nix-personal flake used to add such accounts via
        `extraHomeModules`; it was fully retired 2026-09-15 and only the
        operator's own two were carried over.) All accounts share ONE Google Cloud
        OAuth Desktop-app client (GMAIL_OAUTH_CLIENT_ID/SECRET in the
        Keychain); each account ALSO needs its OWN completed one-time browser
        auth (~/.gmail-mcp/credentials-<sanitized-email>.json) BEFORE being
        added here — an account with no completed auth exits at startup,
        darkening that one gateway entry (not the whole gateway, since each
        is its own process).
      '';
    };

    chromeDevtools = {
      enable = lib.mkEnableOption ''
        Google's chrome-devtools-mcp in the gateway, in ATTACH mode against a browser
        that already has remote debugging on — found via `--autoConnect` reading
        `DevToolsActivePort` out of `userDataDir`, NOT via a fixed port. Performance
        traces, network, console with source-mapped stacks, and the viewport emulation
        (`resize_page`) that automates the userscript method's otherwise-manual "reach
        state B" step. OFF by default for TWO independent reasons, either of which alone
        would justify it: (1) mcp-proxy spawns every hosted server at startup, and in
        attach mode this one is useless until a browser has debugging enabled — either
        in-browser at `chrome://inspect/#remote-debugging` or via `nix-chromium-debug`;
        (2) enabling it is a SECURITY decision — remote debugging is an UNAUTHENTICATED
        control channel, and upstream states plainly that "Any application on your
        machine can connect", i.e. any local process can then read that browser's pages,
        cookies and session state and act as the signed-in user. This Mac's browsers hold
        the Apple Passwords native host and live logins, so treat a debug-enabled session
        as exposed for its whole lifetime and quit it when finished. Telemetry flags are
        set for you (--no-usage-statistics, --no-performance-crux); the second is the one
        that otherwise sends TRACED URLS to Google's CrUX API. Behaviour, the measured
        tool surface and both attach modes: the in-repo `page-lab` plugin'';

      port = lib.mkOption {
        type = lib.types.port;
        default = 9222;
        description = ''
          Loopback port probed FIRST for a live `/json/version`. When it answers, the
          server attaches with `--browser-url` and the browser's own live
          `webSocketDebuggerUrl` is used; when nothing answers on any candidate port the
          server falls back to `--autoConnect` against `userDataDir`.

          9222 is the conventional CDP port AND the one `nix-chromium-debug` opens by
          default, so the probe hint and the launcher now agree. It was 61867 until
          2026-09-21 — the port Opera Air picked for itself in consent mode — but Opera
          was removed from this Mac that day, so pinning its port outlived its reason.
          It binds to 127.0.0.1 only — never expose or forward it; that turns a
          local-only debugging channel into a remote one.

          This is a probe HINT, not the whole answer: line 1 of the profile's
          `DevToolsActivePort` is probed as a second candidate, so a browser that picked
          a different port is still found.
        '';
      };

      userDataDir = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/Library/Application Support/Chromium";
        example = "${config.home.homeDirectory}/Library/Application Support/Google/Chrome";
        description = ''
          Browser profile directory `--autoConnect` reads `DevToolsActivePort` from — the
          file the browser writes when its debugging server starts, naming the port it
          actually chose and the browser WebSocket path. This, not a port number, is how
          the server finds the browser [F-AUTOCONNECT-USERDATADIR].

          It is a directory rather than a port BECAUSE the port is no longer knowable in
          advance: a browser put into debugging mode from `chrome://inspect/#remote-debugging`
          picks its own (measured 2026-09-07 on the since-removed Opera Air: 61867), and
          the browser WebSocket UUID
          changes on every launch. Both live in `DevToolsActivePort`, so upstream resolving
          it at connect time is the only shape that survives a browser restart.

          Defaults to Chromium, the browser this fleet enables debugging on since Opera
          was removed (2026-09-21). Point it at any Chromium-family profile — the layout
          is the same. Note this is the USER DATA dir (the
          one holding `DevToolsActivePort` and `Default/`), not the `Default/` profile inside it.
        '';
      };
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
    # `nix-chromium-debug` — the CLASSIC, launch-flag route to the CDP port.
    #
    # NO LONGER THE ONLY ROUTE, and no longer the one this module's server assumes.
    # A running browser CAN now be switched into debugging mode from
    # `chrome://inspect/#remote-debugging` (Chrome/Chromium M144+),
    # which is how the browser this gateway attaches to is actually enabled — it
    # picks its own port and writes it to `DevToolsActivePort` [F-NO-JSON-HTTP].
    # This wrapper stays for the flag route, which is still the only way to open a
    # port on a browser whose UI toggle you do not want to use, and the only way to
    # get a debug port on an --isolated throwaway profile.
    #
    # It launches CHROMIUM specifically. `chromeDevtools.userDataDir` selects which
    # profile the SERVER attaches to and now also defaults to Chromium, so the two
    # AGREE out of the box — they stayed independent knobs, though: point userDataDir
    # at another Chromium-family profile and this wrapper still launches Chromium.
    # (Until 2026-09-21 the default was Opera Air, which is no longer installed.)
    #
    # Why a wrapper at all, rather than a declared browser flag: the .app is a
    # Homebrew cask, so `programs.chromium.package` is null, and upstream's own
    # assertion then FORBIDS `commandLineArgs` — there is no Nix wrapper to pass
    # them to (see modules/shared/chromium.nix).
    #
    # Deliberately a hand-run command and NOT a launchd agent or a login item: the
    # port is an unauthenticated control channel over a browser holding live logins
    # and the Apple Passwords native host. It should exist for a session, on
    # purpose, and die with the window — never come back at boot.
    home.packages = lib.mkIf cfg.chromeDevtools.enable [
      (pkgs.writeShellScriptBin "nix-chromium-debug" ''
        set -euo pipefail
        # 9222 is the de-facto default every CDP client assumes. Bound to 127.0.0.1
        # only — never expose or forward it; that turns a local-only debugging
        # channel into a remote one.
        port="''${1:-9222}"

        # Relaunching while the same profile is already running silently reuses the
        # existing process and the port never opens — indistinguishable from the
        # flag being ignored, and it cost real debugging time to learn. Refuse
        # instead of producing a browser that looks right and is not.
        if /usr/bin/pgrep -x "Chromium" >/dev/null 2>&1; then
          echo "nix-chromium-debug: Chromium is already running." >&2
          echo "  --remote-debugging-port is a STARTUP flag, so it cannot be added to" >&2
          echo "  this process. Either quit Chromium completely and re-run, or leave it" >&2
          echo "  running and turn debugging on in-browser at chrome://inspect/#remote-debugging" >&2
          echo "  — that needs no relaunch, and the server finds the port it picks." >&2
          exit 1
        fi

        echo "nix-chromium-debug: opening CDP on 127.0.0.1:$port" >&2
        echo "  WARNING: any local process can now drive this browser and read its" >&2
        echo "  pages, cookies and session state. Quit Chromium when you are done." >&2
        exec /usr/bin/open -na "Chromium" --args "--remote-debugging-port=$port"
      '')
    ];

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

        # ✅ upstream option `SoftResourceLimits.NumberOfFiles` exists → using it
        # (pinned home-manager modules/launchd/launchd.nix:471 and :521; 4096 is
        # upstream's OWN example value at :567). No supervisor, no health-check
        # daemon, no retry wrapper — launchd already models this.
        #
        # THE TRAP: a launchd agent inherits launchd's limit, not a shell's.
        # Measured 2026-09-22:
        #   launchctl limit maxfiles  ->  256 soft
        #   ulimit -n (interactive)   ->  1048576
        #   lsof -p <proxy> | wc -l   ->  106   (41% of 256 at STEADY STATE)
        # So mcp-proxy run by hand works and the same binary under launchd does
        # not — which is why this never looked like a resource problem.
        #
        # WHY IT BLOWS: mcp-proxy spawns and fully handshakes each named server
        # SEQUENTIALLY (mcp_server.py:183 loop; proxy_server.py:18 awaits
        # `initialize()`), each child costing at least 3 pipe fds plus whatever it
        # opens. 26 of those on top of a 106-fd baseline exhausts 256 mid-loop:
        # `OSError: [Errno 24] Too many open files`, 6,240 occurrences in
        # ~/Library/Logs/mcp-gateway.log before this was found.
        #
        # AND IT IS NOT PARTIAL. All 26 children live in one AsyncExitStack, and
        # the listening socket is not created until the loop completes
        # (Starlette at :222, uvicorn.Server at :237). So the failure is not "some
        # servers missing" — it is the whole gateway, and startup is binary:
        # connection-refused, then fully ready. That is also why the portal latched
        # `status = error` on servers that were fine; it was being REFUSED, not
        # reading a half-ready proxy.
        #
        # Not a workaround, so it has no retirement condition: it is the correct
        # limit for a process that fans out to 26 children. Revisit only if 4096 is
        # ever approached, which at 106 steady-state would mean a leak.
        SoftResourceLimits.NumberOfFiles = 4096;

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

    # The connector, and the ONLY way anything reaches the proxy. No longer
    # conditional: with clients going through the portal, a gateway without a
    # tunnel is a gateway nothing can talk to.
    launchd.agents.mcp-tunnel-connector = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe mcpTunnelConnector) ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcp-tunnel-connector.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcp-tunnel-connector.log";
      };
    };

    # The assertions that policed `local.mcpGateway.public` are GONE with the
    # option. They refused a published name the gateway did not host, and refused
    # `desktop-commander` / `open-design` outright. Neither is expressible now:
    # there is no subset to get wrong, `open-design` was removed from the fleet,
    # and `desktop-commander` is published deliberately.
    #
    # What replaces them is `checks.<system>.mcp-published-parity`, which asserts
    # the hosted roster equals `config.fleet.publicMcpServers` — catching the
    # direction the old assertion could not: a newly hosted server that nobody
    # remembered to publish.

    # ---- The hub: one declaration, every client ------------------------------
    programs.mcp = {
      enable = true;
      servers = hubServers;
    };

    # ---- Client side A: Claude Code (home-manager module) ----------------------
    # upstream option home-manager.programs.claude-code.enableMcpIntegration
    # exists → using it (pinned claude-code/options.nix:41-59; merge at
    # default.nix:47-50, where `mcpServers` entries win on collision). Nothing is
    # declared here any more: the two per-client stdio servers are gone —
    # `desktop-commander` moved onto the proxy, `open-design` was removed from the
    # fleet — so the hub's single portal entry is the whole client config.
    programs.claude-code.enableMcpIntegration = true;

    # ---- Client side B: VS Code (home-manager-managed) -------------------------
    # upstream option home-manager.programs.vscode.profiles.<n>.enableMcpIntegration
    # exists → using it (pinned mkVscodeModule.nix:123-134; the user mcp.json is
    # written at :393-411 with `servers` as the top-level key and `type = "http"`
    # added per entry — the exact file a hand-written home.file produced here
    # until 2026-09-13, one profile setting away from a collision). GATED on
    # programs.vscode.enable: drop VS Code and nothing is written.
    programs.vscode.profiles.default.enableMcpIntegration = lib.mkIf config.programs.vscode.enable true;

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
    # upstream-first: grepped nix-darwin/modules for Accessibility/TCC — the
    # option EXISTED and was REMOVED. `modules/alias.nix:13-21` keeps
    # `security.enableAccessibilityAccess` only to assert on it: "was removed,
    # it's broken since 10.12 because of SIP". So the grant cannot be declared by
    # anyone, which is exactly why this shim only CHECKS and reports it and never
    # tries to set it. Upstream's own removal is the citation.
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
