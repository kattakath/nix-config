# Claude Code routing telemetry: a local OpenTelemetry Collector receiving
# Claude Code's native OTLP logs export, writing claude_code.tool_decision /
# tool_result events to a rotating JSONL file for periodic /routing-review
# analysis — the deterministic-vs-model-judgment signal for deciding which
# tool/skill routing decisions are worth hardening into a hook or command.
# See docs/claude-code-observability-runbook.md.
#
# Events stay local: the logs pipeline writes only the JSONL file, and no
# prompt/response content is exported (OTEL_LOG_USER_PROMPTS/OTEL_LOG_ASSISTANT_RESPONSES
# stay unset). Since ADR-011 (docs/observability-hub-adr.md § 3) METRICS also leave
# the machine when `grafana.enable` is set: cost, tokens, active time, commits/PRs, with
# every identity attribute stripped before export (`attributes/strip` below).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.claudeOtel;
in
{
  options.local.claudeOtel = {
    enable = lib.mkEnableOption "local OTel Collector receiving Claude Code's routing-decision telemetry";

    otlpEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:4317";
      description = ''
        Localhost OTLP gRPC endpoint the collector listens on and that
        Claude Code (via programs.claude-code.settings.env) exports to.
      '';
    };

    eventsFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/state/claude-otel/events.jsonl";
      description = ''
        Rotating JSONL file the collector's file exporter writes claude_code.*
        events to (rotated at 50 MiB, 5 backups kept). Read by /routing-review.
      '';
    };

    grafana = {
      enable = lib.mkEnableOption "a metrics pipeline exporting Claude Code's native metrics to Grafana Cloud over OTLP/HTTP";

      # Item NAMES, not values: endpoint, instance id and token are all read from the
      # login Keychain at agent start (`secret exec`), so no per-person value sits in
      # the store or the repo. Missing items fall back to the local-only config.
      endpointItem = lib.mkOption {
        type = lib.types.str;
        default = "grafana:otlp:endpoint";
        description = "Keychain item holding the OTLP gateway base URL (…/otlp).";
      };
      instanceItem = lib.mkOption {
        type = lib.types.str;
        default = "grafana:otlp:instance";
        description = "Keychain item holding the stack instance id (the basic-auth user).";
      };
      tokenItem = lib.mkOption {
        type = lib.types.str;
        default = "grafana:otlp:token";
        description = "Keychain item holding the write token (the basic-auth password).";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    let
      # cfg.otlpEndpoint is a full URL ("http://host:port") since that's what
      # OTEL_EXPORTER_OTLP_ENDPOINT (the Claude Code side, in default.nix) needs;
      # the collector's own YAML wants bare "host:port" — derive it here so
      # there's exactly one source of truth for the port, not two hardcoded
      # copies that could silently drift apart if this option is ever changed.
      grpcHostPort = lib.removePrefix "http://" cfg.otlpEndpoint;
      # Rendered with builtins.toJSON — JSON is YAML, and the collector reads it as
      # such — so the two configs share these attrsets instead of splicing text.
      receivers.otlp.protocols = {
        grpc.endpoint = grpcHostPort;
        # Not surfaced as an option — Claude Code only ever speaks grpc
        # (OTEL_EXPORTER_OTLP_PROTOCOL in default.nix); this is purely a
        # manual-probe convenience (curl http://.../v1/logs).
        http.endpoint = "127.0.0.1:4318";
      };
      fileExporter = {
        path = cfg.eventsFile;
        rotation = {
          max_megabytes = 50;
          max_backups = 5;
        };
      };
      logsPipeline = {
        receivers = [ "otlp" ];
        processors = [ "batch" ];
        exporters = [ "file" ];
      };
      # Local only: logs to the JSONL file. With no metrics pipeline the receiver
      # drops any metrics Claude Code sends — the fallback when a Keychain item is
      # missing.
      localConfig = pkgs.writeText "claude-otel-config.yaml" (
        builtins.toJSON {
          inherit receivers;
          processors.batch = { };
          exporters.file = fileExporter;
          service.pipelines.logs = logsPipeline;
        }
      );
      del = key: {
        inherit key;
        action = "delete";
      };
      # `${env:…}` is the collector's own config-provider syntax, resolved at start
      # from the environment `secret exec` builds — never written to the store.
      grafanaConfig = pkgs.writeText "claude-otel-grafana-config.yaml" (
        builtins.toJSON {
          inherit receivers;
          extensions."basicauth/grafana".client_auth = {
            username = "\${env:GRAFANA_OTLP_INSTANCE}";
            password = "\${env:GRAFANA_OTLP_TOKEN}";
          };
          processors = {
            batch = { };
            # Claude Code ALWAYS attaches user.email, organization.id and user.id to
            # metrics (code.claude.com/docs/en/monitoring-usage § Standard attributes);
            # the env vars in default.nix only turn off session.id and the account
            # ids. Deleting here is the guarantee; the env vars only cut what is sent.
            "attributes/strip".actions = map del [
              "user.email"
              "user.id"
              "user.account_uuid"
              "user.account_id"
              "organization.id"
              "session.id"
              "ccr.session.id"
              "terminal.type"
            ];
            "resource/strip".attributes = map del [
              "user.email"
              "host.name"
            ];
          };
          exporters = {
            file = fileExporter;
            "otlphttp/grafana" = {
              endpoint = "\${env:GRAFANA_OTLP_ENDPOINT}";
              auth.authenticator = "basicauth/grafana";
            };
          };
          service = {
            extensions = [ "basicauth/grafana" ];
            pipelines = {
              logs = logsPipeline;
              metrics = {
                receivers = [ "otlp" ];
                processors = [
                  "attributes/strip"
                  "resource/strip"
                  "batch"
                ];
                exporters = [ "otlphttp/grafana" ];
              };
            };
          };
        }
      );
      g = cfg.grafana;
      otelcol = lib.getExe' pkgs.opentelemetry-collector-contrib "otelcol-contrib";
      # launchd-naming: arg0 is nix-claude-otel-collector, never a bare sh.
      # `secret` comes from the Home Manager profile, the runtime path every shell uses.
      collector = pkgs.writeShellScriptBin "nix-claude-otel-collector" ''
        secret=${config.home.profileDirectory}/bin/secret
        ${lib.optionalString g.enable ''
          if "$secret" fp ${lib.escapeShellArg g.endpointItem} >/dev/null 2>&1 \
            && "$secret" fp ${lib.escapeShellArg g.instanceItem} >/dev/null 2>&1 \
            && "$secret" fp ${lib.escapeShellArg g.tokenItem} >/dev/null 2>&1; then
            exec "$secret" exec \
              GRAFANA_OTLP_ENDPOINT=${lib.escapeShellArg g.endpointItem} \
              GRAFANA_OTLP_INSTANCE=${lib.escapeShellArg g.instanceItem} \
              GRAFANA_OTLP_TOKEN=${lib.escapeShellArg g.tokenItem} \
              -- ${otelcol} --config ${grafanaConfig}
          fi
          echo "nix-claude-otel-collector: a Grafana Keychain item is missing; running local-only" >&2
        ''}
        exec ${otelcol} --config ${localConfig}
      '';
    in
    {
      # packages/claude-otel-doctor.nix is a generic flake package and reads these first;
      # its own defaults are only fallbacks, so a changed option reaches it here.
      home.sessionVariables = {
        CLAUDE_OTEL_OTLP_HOST_PORT = grpcHostPort;
        CLAUDE_OTEL_EVENTS_FILE = cfg.eventsFile;
      };

      # The file exporter does not create its parent directory — ensure it
      # exists before the collector's first write attempt.
      # upstream-first: grepped home-manager/modules/files.nix — `home.file`
      # LINKS files (and `recursive` only changes how a directory's contents are
      # linked); there is no option that declares an empty directory. One mkdir
      # is the smallest thing that closes the gap.
      home.activation.claudeOtelStateDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        /bin/mkdir -p ${lib.escapeShellArg (builtins.dirOf cfg.eventsFile)}
      '';

      launchd.agents.claude-otel-collector = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe collector) ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/claude-otel-collector.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-otel-collector.log";
        };
      };
    }
  );
}
