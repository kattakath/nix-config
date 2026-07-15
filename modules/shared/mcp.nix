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
#   `mcp-proxy --named-server-config <gatewayConfig>` hosts all 9 servers, each
#   reachable at /servers/<name>/sse. `gatewayConfig` is rendered by
#   mcp-servers-nix's `lib.mkConfig`, so the 4 packaged servers
#   (context7/fetch/memory/sequential-thinking) are PINNED store-path commands;
#   the 5 without a module fall back to pinned npx/uvx launchers (still a runtime
#   fetch, but acceptable on the Mac where Node/uv already live).
#
# CLIENT SIDE (programs.claude-code.mcpServers)
#   The 9 hosted servers are wired as `type = "http"` (Streamable HTTP — the
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
  # localhost-only gateway endpoint.
  gatewayHost = "127.0.0.1";
  gatewayPort = 8096;

  # Pinned launchers for the servers mcp-servers-nix does not package. Absolute
  # store paths so they resolve under launchd's minimal PATH.
  npx = lib.getExe' pkgs.nodejs "npx";
  uvx = lib.getExe' pkgs.uv "uvx";

  # The 5 servers with no mcp-servers-nix module, as raw stdio commands. Merged
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
  };

  # Every server NAME the gateway hosts (4 packaged + 5 custom). Single source
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
  # settings.servers carries the 5 custom ones verbatim. flavor "claude-code"
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

  # CLIENT SIDE: each hosted server as a Streamable HTTP entry.
  httpClientEntries = lib.genAttrs hostedServerNames (name: {
    type = "http";
    url = endpointFor name "mcp";
  });
in
lib.mkIf pkgs.stdenv.isDarwin {
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

  # ---- Client side: point Claude Code at the gateway -------------------------
  programs.claude-code.mcpServers = httpClientEntries // {
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
}
