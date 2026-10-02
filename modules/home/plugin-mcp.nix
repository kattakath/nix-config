# Credentialed stdio-MCP launchers on PATH, for the PLUGIN lane.
#
# WHY THIS MODULE EXISTS. The MCP gateway was purged from macOS
# (`local.mcpGateway.enable = false`). Most of its servers had a plugin owner already and
# went home with it; three CREDENTIALED ones did not, and the operator chose to keep the
# capability rather than let it go dark:
#
#   wordpress   site administration over the WP REST API against silvercreek.ai PROD
#   apify       Apify Store Actors — the rag-web-browser / web-fetch scraping lane
#   postgres    the LOCAL pgvector RAG store (NOT a hosted Postgres; the Neon connector
#               covers Neon projects and cannot see 127.0.0.1:5433)
#
# THE SPLIT, identical to `local.gmailMcp`'s and for the same reason:
#   HERE          the launcher binaries, because they read the login Keychain (or a
#                 fleet-internal coordinate) and must not be duplicated into a plugin repo.
#   THE PLUGIN    a `.mcp.json` in github:kattakath/skills naming each launcher by BINARY
#                 NAME, so Claude Code spawns one stdio server per session with no proxy
#                 and nothing shared between clients.
#
# A plugin's `.mcp.json` can set `env` to literals or passthroughs but cannot run
# `security find-generic-password`, which is the whole reason the credential half stays
# in Nix. Secret NAMES live here; no secret VALUE ever reaches the store or argv.
#
# This is NOT the gateway returning: no long-lived process, no listening socket, no
# tunnel, no portal. Claude Desktop loads no plugins, so none of these three reach it —
# that capability is genuinely gone for Desktop and no declaration here changes it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.pluginMcp;

  # Per-server shape, read out of the purged `modules/shared/mcp.nix` — its
  # `catalogArgOverrides` (the pins) and `requiredEnvToPasswordCommand` (the Keychain
  # service ids) — rather than from an upstream README. The pins are the measured part:
  # the gateway spawned every server at startup and ONE failing import darked all of
  # them, which is why each `-y <pkg>@<version>` and each `--python` is here.
  servers = {
    # docdyhr/mcp-wordpress, ~59 tools over the WP REST API. `@3.3.30` pins the client
    # library. Three Keychain reads, not one: the SITE URL is stored too, so the live
    # host never appears in a public repo or in this file.
    #
    # VERIFIED LIVE 2026-10-02, because a plugin for a dead endpoint is worse than no
    # plugin: `https://silvercreek.ai/wp-json/` returns 200 with the `wp/v2` namespace
    # present and advertises `application-passwords` auth, and
    # `/wp-json/wp/v2/users/me` returns 401 `rest_not_logged_in` — the route exists and
    # only authentication gates it. Its SIBLING `wordpress-adapter` is a different
    # endpoint and is DEAD: the `mcp` namespace is absent from that same root and
    # `/wp-json/mcp/mcp-adapter-default-server` 404s `rest_no_route` (the failure that
    # darked all 25 gateway servers, removed in #725). The adapter is deliberately NOT
    # given a home here.
    wordpress = {
      interpreter = "npx";
      args = [
        "-y"
        "mcp-wordpress@3.3.30"
      ];
      keychainEnv = {
        WORDPRESS_SITE_URL = "mcp:silvercreek.ai:wp_url";
        WORDPRESS_USERNAME = "mcp:silvercreek.ai:wp_user";
        WORDPRESS_APP_PASSWORD = "mcp:silvercreek.ai:wp_app_password";
      };
    };

    # apify/actors-mcp-server run LOCALLY against APIFY_TOKEN — NOT the hosted
    # mcp.apify.com OAuth bridge used until 2026-08-19, whose interactive browser
    # redirect a spawned stdio server cannot complete any more than a launchd agent could.
    apify = {
      interpreter = "npx";
      args = [
        "-y"
        "@apify/actors-mcp-server"
      ];
      keychainEnv.APIFY_TOKEN = "mcp:apify.com:token";
    };

    # crystaldba's postgres-mcp ("Postgres MCP Pro") — a general SQL executor, so every
    # pgvector operation is just SQL it can run. The official
    # @modelcontextprotocol/server-postgres is ARCHIVED with an unpatched
    # read-only-bypass SQL-injection CVE and is deliberately avoided.
    #
    # The ONLY one of the three with no secret: `databaseUri` is loopback `trust` auth
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
    postgres = {
      interpreter = "uvx";
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

      Each one is claimed by a plugin in github:kattakath/skills that declares a server
      whose `command` is that binary name. Enabling a name here without the plugin
      installed just leaves an unused binary on PATH; installing the plugin without the
      name here leaves a server that cannot start.

      Empty by default and set PER HOST: which third-party accounts the operator holds is
      identity, not fleet shape — a template consumer wants the mechanism without
      inheriting someone else's WordPress site or Apify billing.

      Credentials come from the login Keychain at launch (`wordpress`, `apify`), so no
      secret is in the store or in this list. `postgres` needs none — its URI is
      loopback `trust`.
    '';
  };

  # Darwin-gated: the launchers read the macOS login Keychain via /usr/bin/security, and
  # the pgvector store is a darwin-only launchd agent. On Linux the option exists and does
  # nothing, which keeps hosts/*.nix free of platform conditionals.
  config = lib.mkIf (cfg.servers != [ ] && pkgs.stdenv.hostPlatform.isDarwin) {
    # Declaring the postgres server while its database is switched off would ship a server
    # that cannot connect — the exact "plugin for a dead endpoint" failure this module's
    # header warns about, so it fails at eval instead of at first tool call.
    assertions = [
      {
        assertion = !(builtins.elem "postgres" cfg.servers) || config.local.rag.pgvector.enable;
        message = "local.pluginMcp.servers includes \"postgres\", but local.rag.pgvector.enable is false — the launcher would point DATABASE_URI at a store that is not running.";
      }
    ];

    home.packages = map (
      name:
      pkgs.callPackage ../../packages/keychain-mcp.nix { } (
        servers.${name}
        // {
          inherit name;
          inherit (config.home) homeDirectory;
        }
      )
    ) cfg.servers;
  };
}
