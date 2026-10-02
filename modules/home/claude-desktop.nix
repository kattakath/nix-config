# Client side D: Claude Desktop (and, through its device bridge, Cowork).
#
# WHAT THIS DOES
# Rendered the SAME MCP connector Claude Code got — the Cloudflare portal in
# front of the gateway — into Claude Desktop's own
# config file, ~/Library/Application Support/Claude/claude_desktop_config.json.
# Desktop does not read ~/.claude/*, .mcp.json, or the home-manager MCP hub, so
# without this the gateway's whole roster reached Claude Code only. Portal and
# gateway are both DELETED (2026-10-02): `gatewayServers = { }` below means the
# rendered block is now EMPTY, and only `extraServers` can still add an entry.
#
# ZERO entries, and that is the end state. The history, so the shape of the code
# below makes sense: until 2026-09-22 this rendered an attrset of one loopback URL
# per hosted server (26 of them at the time), one shim process each; the portal
# collapse replaced all 26 with a single Workspace-authenticated entry; the
# 2026-10-02 purge deleted the portal too. `gatewayServers = { }` below is what is
# left, so NO count here tracks any roster and `extraServers` is the only way an
# entry ever appears again.
#
# THE PLUGIN CONSEQUENCE — a plugin-owned MCP server NEVER reaches Desktop, and
# since the purge that is EVERY server the fleet has. Marketplace plugins are a
# CLAUDE CODE surface: Claude Code loads an enabled plugin's `.mcp.json`, and
# Desktop loads no plugins at all. There is no second channel left to make up the
# difference — the connector that used to be it is destroyed infrastructure. So
# every fleet MCP server is CLAUDE-CODE-ONLY: absent from Claude Desktop, and
# absent from the Cowork bridge behind it. Nothing in this repo can notice, either
# — no check here can read a plugin's `.mcp.json`. The operator accepted that cost
# for the eight servers moving in #657 (the decision is #658 + #657) and then for
# the rest of the roster with the purge.
#
# WHAT COWORK GETS FROM THIS FILE: nothing. A linked Cowork cloud session is
# proxied whatever Desktop loads, as mcp__remote-devices__<name>__*, and this file
# now contributes zero entries to that — whatever Desktop loads, it loads from its
# own installed Desktop Extensions and from entries the operator added by hand, not
# from here. This file is NOT what gives Cowork the fleet's servers; nothing is.
#
# THE TRANSPORT TRAP (why `toStdioShim` is still here with nothing to shim)
# Desktop's parser accepts ONLY the stdio shape — {command, args, env}. A
# `url` or `type` key fails its schema validation and the entry is dropped (or
# the whole mcpServers block is). So any `url`-shaped entry must be wrapped in
# `mcp-remote` (geelen/mcp-remote: a stdio⇄Streamable-HTTP bridge), pinned by
# version and launched by a store-path npx — a shim, not a server: one thin
# bridge process, with any OAuth handshake happening inside it. The portal was
# the one entry that needed this and it is gone; the transform stays because
# `extraServers` still accepts a `url` entry and would hit the same parser.
#
# `checks.<system>.claude-desktop-config-shape` READS NO GATEWAY OPTION ANY
# MORE: `local.mcpGateway.portalEndpoint` went with the portal on 2026-10-02
# and exists nowhere in the tree, under either name. It reads
# `local.claudeDesktop.{enable,renderedServers}` (modules/parts/checks.nix) and
# asserts four things — the module is ENABLED (a disabled writer leaves stale
# content on disk unmanaged, which is the regression that got through), the
# rendered set is EMPTY, `desktop-commander` is not in it, and any entry that
# IS ever rendered is stdio-shaped ({command,args}, no url/type) and carries
# the NIX_CONFIG_MANAGED marker. No URL is asserted because none is rendered.
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
# DELIBERATELY NOT RENDERED — and sufficient again, since the purge.
#   desktop-commander is already installed in Desktop as a Desktop Extension
#   (.mcpb, `ant.dir.gh.wonderwhy-er.desktopcommandermcp`), so this file has
#   never rendered a second copy. The arm of
#   checks.<system>.claude-desktop-config-shape that names desktop-commander is what
#   ENFORCES that; `excludeServers` does not — it is declared below and read by
#   NOTHING in this module (see its own description).
#
#   The duplicate the exclusion could not see is GONE WITH THE ROUTE THAT MADE IT.
#   Between 2026-09-22 and the purge, desktop-commander sat on the gateway and in
#   publicMcpServers, so Desktop received it through the all-or-nothing portal
#   entry regardless and the exclusion was powerless. The portal is destroyed, this
#   file renders nothing, and the .mcpb extension is once again the only copy — so
#   `excludeServers` is correct AND currently has nothing to do.
#
# SCOPE: darwin only. Deliberately NOT gated on any gateway option — `enable`
# briefly defaulted to `isDarwin && mcpGateway.enable`, which switched the whole
# module off when the gateway was purged and left a stale portal entry on disk for
# a day (see the `enable` option below). Gated further at activation on the Desktop
# support dir existing — no Desktop, no stray file. Desktop reads the file at
# launch: restart it after a switch that changes the set (the activation prints a
# reminder only when it did).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.local.claudeDesktop;

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

  # NO FLEET SERVERS AT ALL, and that is the end state rather than a gap. Was an
  # attrset of 26 loopback URLs until 2026-09-22, then exactly one portal entry
  # until 2026-10-02, and now empty.
  #
  # Desktop's only entry was the gateway portal, and the gateway was purged on
  # 2026-10-02 along with its Cloudflare stack. Desktop loads NO PLUGINS, so the
  # plugin lane that replaced the gateway cannot reach it and nothing else can
  # either — Claude Code's first-party connectors are Claude Code's.
  #
  # The module still runs, deliberately: "Desktop has no MCP servers" is a state
  # something must WRITE. Switching the writer off instead leaves whatever is on
  # disk in place, which is exactly what happened for a day after the purge — a
  # stale `kattakath-portal` entry pointing at destroyed infrastructure, with the
  # sync agent gone too. `checks.*.claude-desktop-config-shape` now asserts both
  # halves: the module is ENABLED and it renders NOTHING.
  #
  # `extraServers` remains the supported way to add one by hand. The merge below
  # keeps FOREIGN entries, so an operator's own additions and `preferences` /
  # `coworkUserFilesPath` survive an empty render.
  gatewayServers = { };

  # `stdioServers` is GONE with the servers it carried: `desktop-commander` moved
  # onto the proxy and `open-design` left the fleet, so Claude Code declares no
  # per-client MCP server for Desktop to inherit. `excludeServers` therefore has
  # nothing left to exclude — kept as an option because `extraServers` still
  # composes, and a consumer may add their own.
  rendered = lib.mapAttrs render (gatewayServers // cfg.extraServers);

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
        # NOT gated on the gateway, and that was a REGRESSION introduced with the
        # 2026-10-01 purge. `&& gw.enable` was here, which meant disabling the
        # gateway disabled THIS WHOLE MODULE — so the `gatewayServers` gating added
        # alongside it became dead code, the merge activation never ran, and
        # claude_desktop_config.json kept naming a portal that had been DESTROYED,
        # with the sync agent gone too so nothing would ever clean it. Measured:
        # mcpServers still held `kattakath-portal` a day after the teardown.
        #
        # The module has to stay ACTIVE to render an EMPTY server set — that is the
        # whole point of the operator's choice to keep it rather than delete it.
        # "Desktop has no MCP servers" is a state something must write; it is not
        # what you get by switching the writer off.
        default = pkgs.stdenv.hostPlatform.isDarwin;
        defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isDarwin";
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
      description = "Pinned mcp-remote version used to shim any `url`-shaped entry into Desktop's stdio-only schema (npm: mcp-remote). Nothing is rendered today, so this is only reached via `extraServers`.";
    };

    excludeServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "desktop-commander" ];
      description = ''
        Server names not to render for Desktop. desktop-commander is the default
        because it is installed there as a Desktop Extension already.

        CURRENTLY UNCONSUMED: nothing in this module reads this list. It filtered
        a `programs.claude-code.mcpServers`-derived set that no longer exists, and
        `gatewayServers` is now empty, so there is nothing to filter. The
        desktop-commander guarantee is carried by
        `checks.<system>.claude-desktop-config-shape`, not by this option.
      '';
    };

    extraServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Additional servers for Desktop only, in the hub shape ({ url } or
        { command, args, env }). A `url` entry is wrapped in the pinned mcp-remote
        shim, because Desktop's schema accepts stdio only. This is the ONLY way an
        entry reaches Desktop now — `gatewayServers` is empty.
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
    # nix-claude-desktop-mcp-sync via modules/home/launchd-launcher.nix, which
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
