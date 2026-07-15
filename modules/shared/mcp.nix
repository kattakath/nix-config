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
# The ./.mcp.json in this repo is project-scoped and overlaps by name — prune it
# if the duplication grates (the gateway's user-scope entries are what Claude uses).
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
      context7.enable = true;
      fetch.enable = true;
      memory.enable = true;
      sequential-thinking.enable = true;
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
        # npx/uvx children need Node/uv on PATH (mcp-proxy itself is absolute above).
        EnvironmentVariables.PATH =
          lib.makeBinPath [
            pkgs.nodejs
            pkgs.uv
          ]
          + ":/usr/bin:/bin";
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
  };
}
