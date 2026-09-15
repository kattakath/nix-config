# Client side D: Claude Desktop (and, through its device bridge, Cowork).
#
# WHAT THIS DOES
# Renders the SAME MCP servers Claude Code gets — the localhost gateway's
# hosted endpoints (modules/shared/mcp.nix) plus the per-client stdio servers
# in programs.claude-code.mcpServers — into Claude Desktop's own config file,
# ~/Library/Application Support/Claude/claude_desktop_config.json. Desktop
# does not read ~/.claude/*, .mcp.json, or the home-manager MCP hub, so
# without this the Mac's 20+ gateway servers (telegram, gmail-<alias>,
# wordpress, memory, …) exist for Claude Code only.
#
# Everything Desktop loads is ALSO proxied into a linked Cowork cloud session
# as mcp__remote-devices__<name>__* (the same path Desktop Commander and
# Kapture take today), so this one file is what gives Cowork the fleet's
# servers without publishing anything on the public gateway.
#
# THE TRANSPORT TRAP (why every gateway entry is an mcp-remote shim)
# Desktop's parser accepts ONLY the stdio shape — {command, args, env}. A
# `url` or `type` key fails its schema validation and the entry is dropped (or
# the whole mcpServers block is). The gateway speaks Streamable HTTP on
# 127.0.0.1, so each hosted server is wrapped in `mcp-remote` (geelen/mcp-remote:
# a stdio⇄Streamable-HTTP bridge), pinned by version and launched by the SAME
# store-path npx the gateway itself uses. Shims, not servers: the gateway still
# hosts exactly one instance of each; Desktop just gets one thin bridge process
# per server.
#
# THE OWNERSHIP TRAP (why an activation merge, not home.file)
# claude_desktop_config.json is STATEFUL and Desktop-owned: today it holds
# `coworkUserFilesPath` and `preferences`, and Desktop writes to it. A
# Nix-managed symlink would fight the app — the same call this repo made for
# Grok's config.toml and for Claude Code's plugin state: never own the whole
# file, merge exactly one key. jq rewrites ONLY `mcpServers`, and inside it
# touches ONLY entries carrying the NIX_CONFIG_MANAGED env marker (ours: prune
# stale, rewrite current) — a server the operator added by hand in Desktop's
# UI survives every rebuild untouched.
#
# UPSTREAM FIRST: grepped home-manager (pinned) modules/programs and
# modules/lib for claude_desktop / claude-desktop — no module exists;
# programs.mcp's hub renders to claude-code, codex, cursor, opencode, vscode,
# zed, crush, antigravity-cli and github-copilot-cli, but has no Claude Desktop
# client → custom, because the renderer target is missing upstream. The hub's
# own renderer seam IS reused: `lib.hm.mcp.transformMcpServer` with one
# extraTransform (the shim) is exactly how the codex module renders — so the
# day upstream grows a claude-desktop client, this file becomes
# `programs.claude-desktop.enableMcpIntegration = true` and the shim transform
# moves upstream with it.
#
# DELIBERATELY NOT RENDERED
#   desktop-commander — already installed in Desktop as a Desktop Extension
#     (.mcpb, `ant.dir.gh.wonderwhy-er.desktopcommandermcp`); a second copy via
#     this file would load the same 20 tools twice.
#
# SCOPE: darwin only, and only when the gateway is on (the endpoints are its).
# Gated further at activation on the Desktop support dir existing — no Desktop,
# no stray file. Desktop reads the file at launch: restart it after a switch
# that changes the set (the activation prints a reminder only when it did).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.local.claudeDesktop;
  gw = config.local.mcpGateway;

  npx = lib.getExe' pkgs.nodejs "npx";
  # Bridge stdio ⇄ Streamable HTTP. Pinned: an unpinned `mcp-remote` would be a
  # silent runtime bump on every Desktop launch. Bump deliberately, here.
  mcpRemote = "mcp-remote@${cfg.mcpRemoteVersion}";

  # The marker that says "nix-config wrote this entry". An env var because it is
  # the ONE extra field Desktop's stdio schema tolerates (attrsOf string) and it
  # is harmless to every server that receives it. Not a name prefix (would leak
  # into tool names) and not a comment (JSON has none).
  marker = "NIX_CONFIG_MANAGED";
  markerValue = "claude-desktop";

  # Hub → stdio shim. The one client-specific transform; everything universal
  # (enabled/disabled, env file-refs, null pruning) is upstream's job.
  toStdioShim =
    server:
    if (server.url or null) != null then
      {
        command = npx;
        args = [
          "-y"
          mcpRemote
          server.url
          "--transport"
          "http-only"
        ];
        env = (server.env or { }) // {
          ${marker} = markerValue;
        };
      }
    else
      server
      // {
        env = (server.env or { }) // {
          ${marker} = markerValue;
        };
      };

  render =
    _name: server:
    lib.hm.mcp.transformMcpServer {
      inherit server;
      extraTransforms = [ toStdioShim ];
      # Desktop's schema: {command, args, env} and nothing else.
      exclude = [
        "url"
        "type"
        "enabled"
        "headers"
      ];
    };

  # Gateway endpoints (name → /mcp URL) come from the ONE place they are built.
  gatewayServers = lib.mapAttrs (_: url: { inherit url; }) gw.endpoints;
  # Per-client stdio servers Claude Code declares directly, minus the one that
  # is already a Desktop Extension.
  stdioServers = removeAttrs config.programs.claude-code.mcpServers cfg.excludeServers;

  rendered = lib.mapAttrs render (gatewayServers // stdioServers // cfg.extraServers);

  desiredJson = pkgs.writeText "claude-desktop-mcp-servers.json" (builtins.toJSON rendered);
  # ONE implementation of the merge, shared by the activation block and the
  # WatchPaths agent below.
  #
  # WHY AN AGENT AND NOT JUST ACTIVATION. The ownership note above was right that
  # Desktop WRITES this file — but not about what that costs. A RUNNING Desktop
  # rewrites it wholesale from its own in-memory state, which does not contain
  # the key we merged in, so the merge is DESTROYED rather than merely unloaded.
  # Measured 2026-09-15: activation merged mcpServers at 07:56:51, Desktop
  # rewrote the file without it at 07:58:31, and `restart Claude Desktop to load
  # it` was unreachable advice by then. Activating with Desktop open lost the
  # whole key, every time.
  #
  # LOOP SAFETY, and why this compares instead of always writing. The original
  # activation `mv`d unconditionally, touching mtime even on a no-op — under a
  # file watch that is a self-retriggering loop. This writes ONLY when the merged
  # result differs from what is on disk, so our own write never wakes the agent
  # again.
  syncScript = pkgs.writeShellApplication {
    name = "claude-desktop-mcp-sync";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = ''
      f=${lib.escapeShellArg cfg.configFile}
      # Desktop not installed / never launched: nothing to merge into.
      [ -d "$(dirname "$f")" ] || exit 0
      [ -s "$f" ] || printf '{}\n' > "$f"
      tmp=$(mktemp)
      # Keep everything; inside .mcpServers keep FOREIGN entries (no marker),
      # drop OUR stale ones, then lay the current rendering on top.
      if jq --arg m ${marker} --arg v ${lib.escapeShellArg markerValue} \
           --slurpfile want ${desiredJson} '
             .mcpServers = (
               ((.mcpServers // {}) | with_entries(select((.value.env[$m] // "") != $v)))
               + $want[0]
             )' "$f" > "$tmp"; then
        if cmp -s "$tmp" "$f"; then
          rm -f "$tmp"
        else
          mv "$tmp" "$f"
          echo "claude-desktop: mcpServers written to $f" >&2
        fi
      else
        rm -f "$tmp"
        echo "claude-desktop: could not merge mcpServers into $f (left untouched)" >&2
        exit 1
      fi
    '';
  };
in
{
  options.local.claudeDesktop = {
    enable =
      lib.mkEnableOption "rendering the fleet's MCP servers into Claude Desktop's claude_desktop_config.json"
      // {
        default = pkgs.stdenv.hostPlatform.isDarwin && gw.enable;
        defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isDarwin && config.local.mcpGateway.enable";
      };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Application Support/Claude/claude_desktop_config.json";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Library/Application Support/Claude/claude_desktop_config.json"'';
      description = "Claude Desktop's stateful config file. Only its `mcpServers` key is ever touched.";
    };

    mcpRemoteVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.14.2";
      description = "Pinned mcp-remote version used for every gateway shim (npm: mcp-remote).";
    };

    excludeServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "desktop-commander" ];
      description = ''
        Names from programs.claude-code.mcpServers NOT to render for Desktop.
        desktop-commander is excluded because it is installed there as a Desktop
        Extension already.
      '';
    };

    extraServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Additional servers for Desktop only, in the hub shape ({ url } or
        { command, args, env }). A `url` entry is shimmed like a gateway one.
      '';
    };

    renderedServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      readOnly = true;
      internal = true;
      default = rendered;
      description = "What will be written under mcpServers — read by checks.claude-desktop-config-shape.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.all (s: s ? command && s ? args && !(s ? url) && !(s ? type)) (
          builtins.attrValues rendered
        );
        message = "local.claudeDesktop: every rendered server must be stdio-shaped ({command,args}); Desktop rejects url/type keys.";
      }
    ];

    # Apply once at activation...
    home.activation.claudeDesktopMcp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${lib.getExe syncScript}
    '';

    # ...and re-apply whenever Desktop rewrites the file out from under us.
    #
    # UPSTREAM FIRST: home-manager (pinned 87c391f) declares WatchPaths itself,
    # modules/launchd/launchd.nix:367, and uses it upstream in
    # modules/services/git-sync.nix:115 — so this is launchd's own file-watch
    # primitive, not a polling loop of ours. arg0 becomes
    # nix-claude-desktop-mcp-sync via modules/shared/launchd-launcher.nix, which
    # is what .claude/rules/launchd-naming.md requires.
    launchd.agents.claude-desktop-mcp-sync = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe syncScript) ];
        # Desktop writes this file on quit and on preference changes; each write
        # wakes the agent, which re-merges only if the result actually differs.
        WatchPaths = [ cfg.configFile ];
        # Repair at login too, so a file clobbered while logged out is correct
        # before Desktop is next launched.
        RunAtLoad = true;
        # Damp a burst of Desktop writes. This is launchd's own default, stated
        # so the ping-pong window is a choice rather than something inherited.
        ThrottleInterval = 10;
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-desktop-mcp-sync.log";
      };
    };
  };
}
