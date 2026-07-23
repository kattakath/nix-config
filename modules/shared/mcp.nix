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
# `userName` (uid 502), so that account must be the one logged into the Mac —
# which it is (the active console user is `ismailkattakath`). If a different
# account owns the GUI session, `darwin-rebuild switch` cannot load the agent.
#
# SERVER SIDE (this box, 127.0.0.1:8096)
#   `mcp-proxy --named-server-config <gatewayConfig>` hosts all 10 servers, each
#   reachable at /servers/<name>/sse. `gatewayConfig` is rendered by
#   mcp-servers-nix's `lib.mkConfig`, so the 4 packaged servers
#   (context7/fetch/memory/sequential-thinking) are PINNED store-path commands;
#   the 6 without a module fall back to pinned npx/uvx launchers (still a runtime
#   fetch, but acceptable on the Mac where Node/uv already live).
#
# CLIENT SIDE (programs.claude-code.mcpServers)
#   The 10 hosted servers are wired as `type = "http"` (Streamable HTTP — the
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
  # Loopback port for the SEPARATE public (OAuth-gated) mcp-proxy. Single-sourced
  # in flake.nix and threaded here + into infra/cloudflare/macos-mcp-tunnel.nix so
  # the tunnel ingress and this proxy can never drift.
  mcpPublicPort,
  ...
}:
let
  cfg = config.services.mcpGateway;

  # localhost-only gateway endpoint.
  gatewayHost = "127.0.0.1";
  gatewayPort = 8096;

  # Android SDK root — the android-commandlinetools Homebrew cask install prefix
  # (mirrors ANDROID_HOME in modules/shared/home.nix). mobile-mcp locates `adb`
  # via $ANDROID_HOME/platform-tools, so the gateway launchd agent below puts this
  # on PATH + exports ANDROID_HOME (unlike osascript, adb is NOT in the base PATH).
  androidSdkHome = "/opt/homebrew/share/android-commandlinetools";

  # The PUBLIC proxy binds a different loopback port; only the Mac cloudflared
  # connector (also loopback) reaches it, and Cloudflare Access gates the edge.
  publicPort = mcpPublicPort;

  # Pinned launchers for the servers mcp-servers-nix does not package. Absolute
  # store paths so they resolve under launchd's minimal PATH.
  npx = lib.getExe' pkgs.nodejs "npx";
  uvx = lib.getExe' pkgs.uv "uvx";

  # The 6 servers with no mcp-servers-nix module, as raw stdio commands. Merged
  # into the gateway config via mkConfig's `settings.servers`.
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
      ];
    };
    # Browser automation via Kapture's Chrome DevTools extension. `bridge` is the
    # stdio<->WebSocket MCP server command — NOT `setup` (that auto-edits each
    # client's config, which we own declaratively here). Inert until the Kapture
    # Chrome extension is installed and its DevTools panel is open on a tab. Under
    # launchd it can't spawn its detached :61822 server (restricted /tmp — logs an
    # EACCES) and falls back to hosting it IN-PROCESS; expected, fine for one gateway.
    kapture = {
      command = npx;
      args = [
        "-y"
        "kapture-mcp"
        "bridge"
      ];
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
    # loopback launchd agent — see modules/shared/postgres-pgvector.nix, which
    # single-sources the URI via services.pgvectorGateway.databaseUri.
    postgres = {
      command = uvx;
      args = [
        "postgres-mcp"
        "--access-mode=unrestricted"
      ];
      env.DATABASE_URI = config.services.pgvectorGateway.databaseUri;
    };
  };

  # Every server NAME the gateway hosts (4 packaged + 6 custom). Single source
  # for the client SSE URLs, so the two sides can never drift.
  packagedServerNames = [
    "context7"
    "fetch"
    "memory"
    "sequential-thinking"
  ];
  hostedServerNames = packagedServerNames ++ builtins.attrNames customStdioServers;

  # SERVER SIDE: a {mcpServers:{name:{command,args,env}}} JSON that mcp-proxy
  # consumes via --named-server-config. mkConfig PINS the 4 packaged servers;
  # settings.servers carries the 6 custom ones verbatim. flavor "claude-code"
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
      fetch.enable = true;
      memory.enable = true;
      sequential-thinking.enable = true;
    };
    settings.servers = customStdioServers;
  };

  # ---- PUBLIC exposure: a SEPARATE kapture-only mcp-proxy + OAuth tunnel ------
  # cfg.publicServers names the subset of hosted servers to expose publicly. They
  # run in their OWN mcp-proxy on publicPort — the personal :8096 gateway
  # (memory/cloudflare/fetch/…) is NEVER on the public port. Split the names the
  # same way the private gateway does: packaged servers via mkConfig `programs`,
  # custom stdio servers via `settings.servers`.
  publicPackaged = builtins.filter (n: builtins.elem n packagedServerNames) cfg.publicServers;
  publicCustom = lib.filterAttrs (n: _: builtins.elem n cfg.publicServers) customStdioServers;
  publicGatewayConfig = mcp-servers-nix.lib.mkConfig pkgs {
    flavor = "claude-code";
    fileName = "mcp-gateway-public.json";
    programs = lib.genAttrs publicPackaged (_: {
      enable = true;
    });
    settings.servers = publicCustom;
  };

  # The Mac cloudflared connector, run as a launchd user agent so it can read the
  # tunnel token from the login Keychain (a system daemon cannot). The token is
  # fetched at launch via `security` (never in argv / never in the store) and
  # handed to cloudflared as TUNNEL_TOKEN in the environment. Absent token => the
  # unit fails and launchd retries, self-healing once `set-secret` stores it.
  cloudflaredConnector = pkgs.writeShellScript "mcp-tunnel-connector" ''
    set -eu
    token="$(/usr/bin/security find-generic-password -a "$(id -un)" -s "${cfg.publicTunnel.tokenKeychainKey}" -w 2>/dev/null || true)"
    if [ -z "$token" ]; then
      echo "mcp-tunnel-connector: no '${cfg.publicTunnel.tokenKeychainKey}' in the login Keychain." >&2
      echo "  Provision the tunnel (nix run .#cf-mcp-apply) then store the printed token:" >&2
      echo "    set-secret ${cfg.publicTunnel.tokenKeychainKey} <token>" >&2
      exit 1
    fi
    export TUNNEL_TOKEN="$token"
    exec ${lib.getExe pkgs.cloudflared} --no-autoupdate tunnel run
  '';

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

  jsonFormat = pkgs.formats.json { };

  # VS Code uses `servers` as the top-level key (NOT `mcpServers` — a mismatch VS
  # Code silently ignores) and takes `type = "http"` directly, so it connects to
  # the SAME gateway processes as claude-code. Same 10 servers, no desktop-commander.
  vscodeMcpJson = builtins.toJSON { servers = httpEntries; };

  # Claude Desktop's config is stdio-oriented, so each gateway server is reached
  # via an `mcp-remote` stdio<->HTTP bridge (npx absolute-pathed — Claude Desktop
  # launches from the GUI with a minimal PATH). Key is `mcpServers` here (Claude
  # Desktop / Cursor convention — the opposite of VS Code's `servers`).
  claudeDesktopMcpServers = jsonFormat.generate "claude-desktop-mcpservers.json" (
    lib.mapAttrs (_: url: {
      command = npx;
      args = [
        "-y"
        "mcp-remote"
        url
      ];
    }) cfg.endpoints
  );

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

    publicServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "kapture" ];
      description = ''
        Subset of hosted server names to expose PUBLICLY as OAuth-gated MCP
        connectors. Each runs in a SEPARATE mcp-proxy on the public loopback port
        (isolated from the personal :8096 gateway), reached only via the Mac
        cloudflared connector behind Cloudflare Access Managed OAuth. Empty => no
        public proxy is started. Must be a subset of the hosted servers.
      '';
    };

    publicTunnel = {
      enable = lib.mkEnableOption ''
        the Mac cloudflared connector that exposes the public mcp-proxy through a
        remotely-managed Cloudflare Tunnel (provisioned by
        infra/cloudflare/macos-mcp-tunnel.nix via `nix run .#cf-mcp-apply`). The
        connector token is read from the login Keychain, so nothing is exposed
        until the operator both provisions the tunnel AND stores the token'';

      tokenKeychainKey = lib.mkOption {
        type = lib.types.str;
        default = "MCP_TUNNEL_TOKEN";
        description = ''
          Login-Keychain secret name (stored via `set-secret <KEY> <token>`)
          holding the bare Cloudflare Tunnel connector token. Read at launch by
          the connector agent — never in argv or the /nix/store.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- Server side: the mcp-proxy launchd user agent -------------------------
    launchd.agents.mcp-gateway = {
      enable = true;
      config = {
        ProgramArguments = [
          (lib.getExe' pkgs.mcp-proxy "mcp-proxy")
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

    # ---- Public side A: the kapture-only OAuth-exposed mcp-proxy ----------------
    # A SECOND mcp-proxy hosting ONLY cfg.publicServers on publicPort, bound to
    # loopback. Only started when publicServers is non-empty. Cloudflare Access
    # (Managed OAuth) gates the edge; this proxy itself does no auth (Access
    # enforces before the request reaches the tunnel). Isolated from the personal
    # :8096 gateway so memory/cloudflare/fetch are never on the public port.
    launchd.agents.mcp-gateway-public = lib.mkIf (cfg.publicServers != [ ]) {
      enable = true;
      config = {
        ProgramArguments = [
          (lib.getExe' pkgs.mcp-proxy "mcp-proxy")
          "--host"
          gatewayHost
          "--port"
          (toString publicPort)
          "--named-server-config"
          "${publicGatewayConfig}"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables.PATH =
          lib.makeBinPath [
            pkgs.nodejs
            pkgs.uv
          ]
          + ":/usr/bin:/bin";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcp-gateway-public.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcp-gateway-public.log";
      };
    };

    # ---- Public side B: the Mac cloudflared connector --------------------------
    # Dials OUT to Cloudflare (opens no inbound port on the Mac) and exposes the
    # public mcp-proxy as mcp.<domain>, gated by the Access app. Token from the
    # login Keychain (see cloudflaredConnector). Inert without the token, so
    # enabling this never exposes anything until the operator provisions + stores.
    launchd.agents.mcp-tunnel-connector = lib.mkIf cfg.publicTunnel.enable {
      enable = true;
      config = {
        ProgramArguments = [ "${cloudflaredConnector}" ];
        RunAtLoad = true;
        KeepAlive = true;
        EnvironmentVariables.PATH = "/usr/bin:/bin";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/mcp-tunnel-connector.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/mcp-tunnel-connector.log";
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

    # ---- Client side C: Claude Desktop (NO home-manager module → merge activation)
    # claude_desktop_config.json is a STATEFUL file the app itself writes
    # (preferences, coworkUserFilesPath, …), and there is no `programs.claude-desktop`
    # module, so we cannot own the whole file. Instead an activation script MERGES
    # only the `mcpServers` key via jq, preserving everything else. Each entry is an
    # mcp-remote stdio<->HTTP bridge to the gateway: the heavy servers still run once
    # in the shared gateway, but Claude Desktop spawns one thin bridge per server (the
    # unavoidable cost of a stdio-only client). `mcpServers` becomes Nix-managed —
    # edit it in `hostedServerNames`, not in the app.
    # GATED on the app being installed (/Applications/Claude.app) — uninstall Claude
    # Desktop and this writes/creates nothing.
    home.activation.claudeDesktopMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cfg="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
      if [ ! -d "/Applications/Claude.app" ]; then
        : # Claude Desktop not installed — nothing to configure, no stray files.
      elif [ -f "$cfg" ]; then
        ${pkgs.jq}/bin/jq --slurpfile m ${claudeDesktopMcpServers} \
          '.mcpServers = $m[0]' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && chmod 600 "$cfg"
      else
        mkdir -p "$(dirname "$cfg")"
        ${pkgs.jq}/bin/jq -n --slurpfile m ${claudeDesktopMcpServers} \
          '{ mcpServers: $m[0] }' > "$cfg" && chmod 600 "$cfg"
      fi
    '';

    # ---- Client side D: Grok CLI (stateful ~/.grok/config.toml → grok owns the merge)
    # No `programs.grok` HM module and a stateful config.toml, so — like Claude Desktop — an
    # activation script merges ONLY the [mcp_servers] tables via grok's OWN CLI, which stays
    # robust to grok's TOML schema (the `enabled` flag, --scope, future keys) since grok, not
    # us, renders it. USER scope (not project) so the servers aren't blocked by grok's
    # folder-trust gate. GATED on the grok binary existing (~/.grok/bin/grok) — no grok
    # installed, nothing runs and no stray files are created (mirrors Claude Desktop's
    # /Applications/Claude.app test). We do NOT lean on grok's [compat.claude] mcps=true scan
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
