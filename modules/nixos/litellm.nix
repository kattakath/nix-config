# LiteLLM — OpenAI-compatible proxy in front of many model providers.
#
# WHY A CUSTOM MODULE? nixpkgs recently gained an upstream `services.litellm`,
# but we keep this small hardened unit deliberately: it mirrors this repo's own
# systemd-hardening conventions (adapted from modules/nixos/cloudflared.nix) and
# its `os.environ/VAR` + agenix `EnvironmentFile` secret model, so a host opts in
# with one flag and no store-leaked keys. It runs the top-level `pkgs.litellm`
# wrapper (proxy extras bundled), not the bare `python3Packages.litellm` library.
#
# NO-OP SAFE: this module is imported for ALL NixOS hosts via flake.nix, but the
# option `services.litellm-proxy.enable` defaults to FALSE. Importing it is a
# graceful no-op — nothing runs, no port is opened, no user is created — until a
# host opts in with `services.litellm-proxy.enable = true;`. Platform branching
# and activation are gated entirely behind that flag.
#
# SECRET HANDLING (never in argv / never in the store): the /nix/store is
# world-readable, so real API keys must never appear in `settings`. The rendered
# config.yaml uses `os.environ/VAR` placeholders (LiteLLM resolves them at
# runtime from the process environment); the actual values arrive out-of-band via
# `environmentFile` — an agenix-decrypted KEY=VALUE file fed to systemd as
# `EnvironmentFile`, exactly like the cloudflared connector token. Keys therefore
# never hit the command line (argv is world-readable via /proc) nor the store.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.litellm-proxy;
  # `pkgs.formats.yaml { }` gives us both a matching option `type` and a
  # `generate` function that renders the attrset to a real config.yaml — one
  # source of truth for the schema and the serializer.
  format = pkgs.formats.yaml { };
  configFile = format.generate "litellm-config.yaml" cfg.settings;
in
{
  options.services.litellm-proxy = {
    enable = lib.mkEnableOption "LiteLLM OpenAI-compatible proxy";

    # Defaults to top-level `pkgs.litellm` (the toPythonApplication wrapper with
    # the proxy extras), which provides the `litellm` console script used by
    # ExecStart via getExe' below. NOT `python3Packages.litellm` (bare library,
    # no proxy deps → runtime ImportError).
    package = lib.mkPackageOption pkgs "litellm" { };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the proxy binds to. Loopback by default — front it with a reverse proxy / tunnel rather than exposing it directly.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "TCP port the proxy listens on.";
    };

    settings = lib.mkOption {
      inherit (format) type;
      description = ''
        LiteLLM proxy configuration, rendered to config.yaml. Never put real
        secrets here — the /nix/store is world-readable. Use `os.environ/VAR`
        placeholders (resolved at runtime from the process environment) and
        supply the actual values via {option}`environmentFile`.
      '';
      default = {
        # Two documented example entries. `api_key`/`api_base` values that would
        # be secret use `os.environ/VAR` so nothing sensitive lands in the store.
        model_list = [
          {
            model_name = "gpt-4o";
            litellm_params = {
              model = "openai/gpt-4o";
              api_key = "os.environ/OPENAI_API_KEY";
            };
          }
          {
            model_name = "llama3";
            litellm_params = {
              model = "ollama/llama3";
              api_base = "http://127.0.0.1:11434";
            };
          }
        ];
        general_settings = {
          # The proxy's admin/master key — resolved at runtime from the env,
          # never baked into the store. Provide it via environmentFile as
          # LITELLM_MASTER_KEY. It stays server-only: distribute per-user VIRTUAL
          # KEYS (issued from the Admin UI / /key/generate) instead of the master
          # key. The Admin UI, virtual keys and SSO all require a database.
          master_key = "os.environ/LITELLM_MASTER_KEY";
          # Enables the DB-backed Admin UI + virtual keys + spend tracking + the
          # SSO user table. Resolved at runtime from the env (a Postgres URL with
          # embedded creds — never a store literal). Point DATABASE_URL at a
          # reachable Postgres via environmentFile. Google SSO additionally needs
          # GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / PROXY_BASE_URL, plus
          # ALLOWED_EMAIL_DOMAINS to restrict to a Workspace domain and
          # (optionally) PROXY_ADMIN_ID to promote the first admin — all supplied
          # via environmentFile; LiteLLM reads them straight from the process env.
          database_url = "os.environ/DATABASE_URL";
        };
      };
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to an environment file with `KEY=VALUE` lines (e.g.
        `OPENAI_API_KEY=…`, `LITELLM_MASTER_KEY=…`), fed to the unit via
        systemd `EnvironmentFile` so the values never appear on the command line
        (argv) nor in the world-readable /nix/store. Point this at an
        agenix-decrypted secret — the same pattern the cloudflared connector uses
        for its tunnel token. The `os.environ/VAR` placeholders in
        {option}`settings` resolve against these values at runtime.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open {option}`port` in the firewall. Off by default — keep the proxy behind a tunnel / reverse proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.litellm = {
      description = "LiteLLM OpenAI-compatible proxy";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        # `litellm` is the console script provided by the package; getExe' is
        # explicit about which binary we mean. Config path is a store file; the
        # secrets it references arrive via EnvironmentFile below.
        ExecStart = "${lib.getExe' cfg.package "litellm"} --config ${configFile} --host ${cfg.host} --port ${toString cfg.port}";
        # agenix-decrypted KEY=VALUE file (OPENAI_API_KEY=…, LITELLM_MASTER_KEY=…);
        # only wired when the host provides one.
        EnvironmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        Restart = "on-failure";
        RestartSec = 5;

        # ---- systemd hardening (adapted from modules/nixos/cloudflared.nix) -----
        DynamicUser = true;
        RuntimeDirectory = "litellm";
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        # NOTE: unlike cloudflared we deliberately DO NOT set
        # MemoryDenyWriteExecute — LiteLLM is Python and its JIT/ctypes paths can
        # need W^X exceptions, which that flag would break.
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        SystemCallArchitectures = "native";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
