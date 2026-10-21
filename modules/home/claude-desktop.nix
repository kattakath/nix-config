# Client side D: Claude Desktop (and, through its device bridge, Cowork).
#
# WHAT THIS DOES
# Renders `extraServers` into Claude Desktop's own config file,
# ~/Library/Application Support/Claude/claude_desktop_config.json. Desktop reads
# none of ~/.claude/*, .mcp.json or the home-manager MCP hub, and it loads NO
# PLUGINS — so a plugin-owned MCP server never reaches Desktop, nor the Cowork
# bridge behind it. `extraServers` is the public lane: it carries `github`
# (modules/home/default.nix).
# A second, PRIVATE lane rides the same merge: `overlayFile`, a hand-placed JSON
# the operator keeps out of this public repo, read at activation only.
#
# THE TRANSPORT TRAP (why `toStdioShim` exists)
# Desktop's parser accepts ONLY the stdio shape — {command, args, env}. A
# `url` or `type` key fails its schema validation and the entry is dropped (or
# the whole mcpServers block is). So a `url`-shaped entry (an HTTP MCP server) is
# wrapped in `mcp-remote` (geelen/mcp-remote: a stdio⇄Streamable-HTTP bridge),
# pinned by version and launched by a store-path npx — a shim, not a server: one
# thin bridge process, with any OAuth handshake happening inside it.
#
# `checks.<system>.claude-desktop-config-shape` reads
# `local.claudeDesktop.{enable,renderedServers}` (modules/parts/checks.nix) and
# asserts: the module is ENABLED (a disabled writer leaves stale content on disk
# unmanaged — the 2026-10-01 regression), only the named server is
# rendered, `desktop-commander` is not among them, and every entry is
# stdio-shaped ({command,args}, no url/type) and carries the NIX_CONFIG_MANAGED
# marker.
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
#   never renders a second copy. The arm of
#   checks.<system>.claude-desktop-config-shape that names desktop-commander is what
#   ENFORCES that.
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

  # The merge below keeps FOREIGN entries, so an operator's own additions and
  # `preferences` / `coworkUserFilesPath` survive every render.
  rendered = lib.mapAttrs render cfg.extraServers;

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

      # The operator overlay (see `overlayFile` below): optional, hand-placed, and
      # read HERE rather than at eval, because its content must never enter the
      # public repo or the store. Missing = none; not {mcpServers:{…}} = ignored.
      ov=${lib.escapeShellArg cfg.overlayFile}
      ovServers='{}'
      if [ -s "$ov" ]; then
        if jq -e '.mcpServers | type == "object"' "$ov" > /dev/null 2>&1; then
          ovServers=$(jq -c '.mcpServers' "$ov")
        else
          echo "claude-desktop: $ov has no mcpServers object (ignored)" >&2
        fi
      fi

      tmp=$(mktemp)
      # Keep everything; inside .mcpServers keep FOREIGN entries (no marker),
      # drop OUR stale ones, then lay the overlay and the current rendering on
      # top. Overlay entries get the SAME stdio shim and marker as `extraServers`
      # (so removing one from the overlay prunes it next run), and the Nix
      # rendering is the right operand, so a Nix-declared name always wins.
      if jq --arg m ${marker} --arg v ${lib.escapeShellArg markerValue} \
           --arg npx ${lib.escapeShellArg npx} --arg remote ${lib.escapeShellArg mcpRemote} \
           --argjson ov "$ovServers" \
           --slurpfile want ${desiredJson} '
             ($ov | with_entries(.value |= (
               if has("url") then
                 { command: $npx,
                   args: ["-y", $remote, .url, "--transport", "http-only"],
                   env: ((.env // {}) + { ($m): $v }) }
               else
                 { command: .command, args: (.args // []),
                   env: ((.env // {}) + { ($m): $v }) }
               end))) as $ovr
             | .mcpServers = (
               ((.mcpServers // {}) | with_entries(select((.value.env[$m] // "") != $v)))
               + $ovr
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
        # Never gate this on anything that can go away: `&& gw.enable` once switched
        # the whole module off with the 2026-10-01 gateway purge, and the stale
        # `kattakath-portal` entry it had written stayed on disk for a day. The set
        # Desktop should see is a state something must WRITE; switching the writer
        # off leaves the old one in place.
        default = pkgs.stdenv.hostPlatform.isDarwin;
        defaultText = lib.literalExpression "pkgs.stdenv.hostPlatform.isDarwin";
      };

    configFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Library/Application Support/Claude/claude_desktop_config.json";
      defaultText = lib.literalExpression ''"''${config.home.homeDirectory}/Library/Application Support/Claude/claude_desktop_config.json"'';
      description = "Claude Desktop's stateful config file. Only its `mcpServers` key is ever touched.";
    };

    overlayFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.configHome}/nix-config/claude-desktop.overlay.json";
      defaultText = lib.literalExpression ''"''${config.xdg.configHome}/nix-config/claude-desktop.overlay.json"'';
      description = ''
        Optional, hand-placed `{ "mcpServers": { … } }` merged at activation (and on
        every Desktop rewrite) for servers this PUBLIC repo must not name — typically a
        symlink into the operator's private marketplace clone. Same hub shape as
        `extraServers`; a `url` entry gets the same mcp-remote shim. Never read at eval,
        so it reaches neither the store nor `renderedServers` (and so not the
        config-shape check either). A Nix-declared name wins over an overlay one.
      '';
    };

    mcpRemoteVersion = lib.mkOption {
      type = lib.types.str;
      default = "0.14.2";
      description = "Pinned mcp-remote version used to shim a `url`-shaped `extraServers` entry into Desktop's stdio-only schema (npm: mcp-remote).";
    };

    extraServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Additional servers for Desktop only, in the hub shape ({ url } or
        { command, args, env }). A `url` entry is wrapped in the pinned mcp-remote
        shim, because Desktop's schema accepts stdio only. This is the only way a
        Nix-declared entry reaches Desktop (the private lane is `overlayFile`).
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
    # UPSTREAM FIRST: home-manager declares WatchPaths itself (the `WatchPaths`
    # option in modules/launchd/launchd.nix) and uses it upstream in
    # modules/services/git-sync.nix — so this is launchd's own file-watch
    # primitive, not a polling loop of ours. arg0 becomes
    # nix-claude-desktop-mcp-sync via modules/home/launchd-launcher.nix, which
    # is what .claude/rules/launchd-naming.md requires.
    launchd.agents.claude-desktop-mcp-sync = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe syncScript) ];
        # Desktop writes this file on quit and on preference changes; each write
        # wakes the agent, which re-merges only if the result actually differs.
        # The overlay too, so an edit to it lands without a rebuild.
        WatchPaths = [
          cfg.configFile
          cfg.overlayFile
        ];
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
