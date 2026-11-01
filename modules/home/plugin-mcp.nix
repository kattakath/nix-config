# Credentialed stdio-MCP launchers on PATH, for the PLUGIN lane.
#
# WHY THIS MODULE EXISTS. The MCP gateway was purged from macOS
# (modules/shared/mcp.nix, deleted 2026-10-02). Most of its servers had a plugin owner already and
# went home with it; three CREDENTIALED ones did not, and the operator chose to keep the
# capability rather than let it go dark. The third, `apify`, left on 2026-10-26 for Apify's
# OFFICIAL plugin — hosted mcp.apify.com with in-client OAuth, so it needs no launcher (see
# the `apify` marketplace in modules/home/default.nix). The two that remain:
#
#   wordpress   site administration over the WP REST API against the operator's PROD site
#   postgres    the LOCAL pgvector RAG store (NOT a hosted Postgres; the Neon connector
#               covers Neon projects and cannot see 127.0.0.1:5433)
#
# THE SPLIT:
#   HERE          the launcher binaries, because they read the login Keychain (or a
#                 fleet-internal coordinate) and must not be duplicated into a plugin repo.
#   THE PLUGIN    a `.mcp.json` in github:kattakath/skills whose server runs the plugin's own
#                 `scripts/launch.sh` with `${user_config.launcher}`; that `launcher` setting
#                 is seeded below with the binary's name, so Claude Code spawns one stdio
#                 server per session with no proxy and nothing shared between clients.
#
# A plugin's `.mcp.json` can set `env` to literals or passthroughs but cannot run
# `security find-generic-password`, which is the whole reason the credential half stays
# in Nix. Secret NAMES live here; no secret VALUE ever reaches the store or argv.
#
# desktop-commander's Seatbelt-fenced launcher was RETIRED 2026-11-01 (operator: the official
# `desktop-commander@claude-plugins-official` plugin only, risk accepted). Only its config.json
# is still planted below, because the official server reads the same file.
#
# This is NOT the gateway returning: no long-lived process, no listening socket, no
# tunnel, no portal. Desktop CHAT runs no plugin stdio server (its Code tab does), so none of
# these reach chat through a plugin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.pluginMcp;

  inherit (config.home) homeDirectory;

  # The config desktop-commander would otherwise write for itself, declared.
  #
  # `welcomeOnboardingEligible` AND `pendingWelcomeOnboarding` are the
  # load-bearing keys, and not for their meaning: config-manager.js:60 mutates the
  # config on startup when `welcomeOnboardingEligible` is undefined. The planted file is
  # a read-only store symlink, so that write FAILS, the init try/catch swallows it, and the server falls
  # back to `getDefaultConfig()` — whose `allowedDirectories: []` means
  # UNRESTRICTED (filesystem.js:164). Declaring both keys is what keeps the
  # in-process layer from silently inverting itself on every start.
  #
  # `blockedCommands` is upstream's own default list, kept verbatim per the
  # operator's decision. It is a convenience layer, not the boundary — it matches
  # command names, so it is trivially sidestepped; nothing behind it is a boundary
  # since the fence retired (operator accepted 2026-11-01).
  desktopCommanderConfig = (pkgs.formats.json { }).generate "desktop-commander-config.json" {
    allowedDirectories = [ "${homeDirectory}/Developer" ];
    telemetryEnabled = false;
    defaultShell = "/bin/zsh";
    fileWriteLineLimit = 50;
    fileReadLineLimit = 1000;
    pendingWelcomeOnboarding = false;
    welcomeOnboardingEligible = false;
    blockedCommands = [
      "mkfs"
      "format"
      "mount"
      "umount"
      "fdisk"
      "dd"
      "parted"
      "diskpart"
      "sudo"
      "su"
      "passwd"
      "adduser"
      "useradd"
      "usermod"
      "groupadd"
      "chsh"
      "visudo"
      "shutdown"
      "reboot"
      "halt"
      "poweroff"
      "init"
      "iptables"
      "firewall"
      "netsh"
      "sfc"
      "bcdedit"
      "reg"
      "net"
      "sc"
      "runas"
      "cipher"
      "takeown"
    ];
  };

  # Per-server shape, read out of the purged `modules/shared/mcp.nix` — its
  # `catalogArgOverrides` (the pins) and `requiredEnvToPasswordCommand` (the Keychain
  # service ids) — rather than from an upstream README. The pins are the measured part:
  # the gateway spawned every server at startup and ONE failing import darked all of
  # them, which is why the `-y <pkg>@<version>` pins and each `--python` are here.
  #
  # `plugin` names the github:kattakath/skills plugin whose `launcher` setting is seeded
  # with this binary (see `pluginConfigs` below); it is stripped before the rest reaches
  # the factory.
  servers = {
    # docdyhr/mcp-wordpress, ~59 tools over the WP REST API. `@3.3.30` pins the client
    # library. Three Keychain reads, not one: the SITE URL is stored too, so the live
    # host never appears in a public repo or in this file.
    #
    # VERIFIED LIVE 2026-10-02, because a plugin for a dead endpoint is worse than no
    # plugin: the site's `/wp-json/` returns 200 with the `wp/v2` namespace
    # present and advertises `application-passwords` auth, and
    # `/wp-json/wp/v2/users/me` returns 401 `rest_not_logged_in` — the route exists and
    # only authentication gates it. Its SIBLING `wordpress-adapter` is a different
    # endpoint and is DEAD: the `mcp` namespace is absent from that same root and
    # `/wp-json/mcp/mcp-adapter-default-server` 404s `rest_no_route` (the failure that
    # darked all 25 gateway servers, removed in #725). The adapter is deliberately NOT
    # given a home here.
    wordpress = {
      plugin = "wordpress";
      interpreter = "npx";
      args = [
        "-y"
        "mcp-wordpress@3.3.30"
      ];
      keychainEnv = {
        # Service names carry no host: `wp_url` already holds the site, so a host in
        # the NAME added nothing but a public client literal (renamed 2026-10-20).
        WORDPRESS_SITE_URL = "mcp:wordpress:wp_url";
        WORDPRESS_USERNAME = "mcp:wordpress:wp_user";
        WORDPRESS_APP_PASSWORD = "mcp:wordpress:wp_app_password";
      };
    };

    # crystaldba's postgres-mcp ("Postgres MCP Pro") — a general SQL executor, so every
    # pgvector operation is just SQL it can run. The official
    # @modelcontextprotocol/server-postgres is ARCHIVED with an unpatched
    # read-only-bypass SQL-injection CVE and is deliberately avoided.
    #
    # No secret: `databaseUri` is loopback `trust` auth
    # with no password, so it is a plain env value rather than a Keychain read — and it
    # comes from the local-rag capsule's own option, so the port/role/db are stated once.
    # `--access-mode=unrestricted` lets it create tables and insert vectors; the blast
    # radius is bounded by the role, which owns ONLY that one database.
    #
    # The two pins are the measured ones: `--python 3.12` steers uv away from a CPython
    # whose wheels pglast's deps lag, and `--with mcp<2 --from postgres-mcp==0.3.0` pins
    # around mcp 2.0 removing the vendored `fastmcp` that 0.3.0 still imports.
    #
    # VERIFIED RUNNING 2026-10-02 before declaring it: postgres is listening on
    # 127.0.0.1:5433 and `postgresql://mcp@127.0.0.1:5433/ragdb` connects with the
    # `vector` extension at 0.8.5.
    #
    # `--overrides` (2026-11-01): 0.3.0, still the latest, pins `pglast==7.2.0`, and PyPI
    # no longer serves a 7.2 release (7.20 is the oldest 7.2x), so uv refused to resolve
    # and the server never started. Overriding to 7.20 measured: 9 tools, `list_schemas`
    # and `explain_query` (pglast's parser path) both answer. Drop it once upstream
    # re-pins.
    postgres = {
      plugin = "rag";
      interpreter = "uvx";
      args = [
        "--python"
        "3.12"
        "--overrides"
        "${pkgs.writeText "postgres-mcp-overrides.txt" "pglast==7.20\n"}"
        "--with"
        "mcp<2"
        "--from"
        "postgres-mcp==0.3.0"
        "postgres-mcp"
        "--access-mode=unrestricted"
      ];
      plainEnv.DATABASE_URI = config.local.rag.pgvector.databaseUri;
    };
  };
in
{
  options.local.pluginMcp.servers = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames servers));
    default = [ ];
    example = [ "postgres" ];
    description = ''
      Which credentialed MCP launchers to put on PATH, one binary each, named
      `nix-mcp-<name>`. An enum rather than free strings, so a typo fails here instead of
      shipping a plugin that names a binary nobody builds.

      Each one is claimed by a plugin in github:kattakath/skills whose `launcher` setting
      is seeded with that binary name (see this module's `pluginConfigs` block). Enabling a name here without the plugin
      installed just leaves an unused binary on PATH; installing the plugin without the
      name here leaves a server that cannot start.

      Empty by default and set PER HOST: which third-party accounts the operator holds is
      identity, not fleet shape — a template consumer wants the mechanism without
      inheriting someone else's WordPress site.

      Credentials come from the login Keychain at launch (`wordpress`), so no
      secret is in the store or in this list. `postgres` needs none — its URI is
      loopback `trust`.
    '';
  };

  # Darwin-gated: the launchers read the macOS login Keychain via /usr/bin/security, and
  # the pgvector store is a darwin-only launchd agent. On Linux the option exists and does
  # nothing, which keeps hosts/*.nix free of platform conditionals.
  config = lib.mkMerge [
    (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
      # The config dir MUST exist before the server starts, and its contents must be
      # declared. Both halves are this one `home.file`:
      #
      #   EXISTENCE — utils/trackTools.js:6 runs `mkdir(dir, {recursive:true})` at
      #     module scope with no try/catch. Measured 2026-10-07: that call survives
      #     when the directory exists and is write-denied, but throws EPERM when the
      #     directory is ABSENT. Absent dir => the server dies at import. Planting a
      #     file inside it is what guarantees existence.
      #   CONTENT — see `desktopCommanderConfig` above for why the onboarding keys
      #     are load-bearing rather than cosmetic.
      #
      # `force = true` is deliberate and needed. UPSTREAM FIRST: `home.file.<n>.force`
      # is a real option in the PINNED home-manager
      # (home-manager/modules/lib/file-type.nix:135), documented as unconditionally replacing the
      # target and "silently delete[ing] the target regardless of whether it is a file
      # or link". Without it activation ABORTS here, because this Mac already carries
      # a REAL config.json at that path — desktop-commander ran outside Nix until the
      # 2026-10-01 purge (1,565 bytes, last written 2026-10-05, 705 tool calls of
      # `usageStats` and a telemetry `clientId`). Nothing in it is worth preserving:
      # the counters cannot accrue into a read-only file, and dropping
      # the `clientId` is the point of `telemetryEnabled = false`.
      home.file.".claude-server-commander/config.json" =
        lib.mkIf (config.local.claudePlugins.declared."desktop-commander@claude-plugins-official" or false)
          {
            source = desktopCommanderConfig;
            force = true;
          };
    })
    (lib.mkIf (cfg.servers != [ ] && pkgs.stdenv.hostPlatform.isDarwin) {
      # Declaring the postgres server while its database is switched off would ship a server
      # that cannot connect — the exact "plugin for a dead endpoint" failure this module's
      # header warns about, so it fails at eval instead of at first tool call.
      assertions = [
        {
          assertion = !(builtins.elem "postgres" cfg.servers) || config.local.rag.pgvector.enable;
          message = "local.pluginMcp.servers includes \"postgres\", but local.rag.pgvector.enable is false — the launcher would point DATABASE_URI at a store that is not running.";
        }
      ];

      # A plugin that STARTS the launcher its operator names (kattakath/skills `rag` and
      # `wordpress`, since 2026-11-01: no fleet default in a public `.mcp.json`) gets that
      # name seeded into its `launcher` setting HERE, next to the binary it names, so the
      # two cannot drift apart. `pluginConfigs.<id>.options` is the store
      # `claude plugin configure` writes (measured, CLI 2.1.296), so this is that command,
      # declared.
      # `checks.<system>.mcp-launcher-parity` holds the far end: that the named plugin
      # exists in the pinned skills tree and passes `${user_config.launcher}` to its server.
      programs.claude-code.settings.pluginConfigs = lib.mkMerge (
        map (name: {
          "${servers.${name}.plugin}@kattakath".options.launcher = "nix-mcp-${name}";
        }) cfg.servers
      );

      home.packages = map (
        name:
        pkgs.callPackage ../../packages/keychain-mcp.nix { } (
          removeAttrs servers.${name} [ "plugin" ]
          // {
            inherit name;
            inherit (config.home) homeDirectory;
          }
        )
      ) cfg.servers;
    })
  ];
}
