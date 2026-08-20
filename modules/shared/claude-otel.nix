# Claude Code routing telemetry: a local OpenTelemetry Collector receiving
# Claude Code's native OTLP logs export, writing claude_code.tool_decision /
# tool_result events to a rotating JSONL file for periodic /routing-review
# analysis — the deterministic-vs-model-judgment signal for deciding which
# tool/skill routing decisions are worth hardening into a hook or command.
# See docs/claude-code-observability-runbook.md.
#
# Events only (OTEL_LOGS_EXPORTER) — no metrics/traces exporter, and no
# prompt/response content (OTEL_LOG_USER_PROMPTS/OTEL_LOG_ASSISTANT_RESPONSES
# stay unset). Everything is localhost-only; nothing leaves the machine.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.claudeOtel;
in
{
  options.services.claudeOtel = {
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
  };

  config = lib.mkIf cfg.enable (
    let
      otelConfig = pkgs.writeTextFile {
        name = "claude-otel-config.yaml";
        text = ''
          receivers:
            otlp:
              protocols:
                grpc:
                  endpoint: 127.0.0.1:4317
                http:
                  endpoint: 127.0.0.1:4318
          processors:
            batch: {}
          exporters:
            file:
              path: ${cfg.eventsFile}
              rotation:
                max_megabytes: 50
                max_backups: 5
          service:
            pipelines:
              logs:
                receivers: [otlp]
                processors: [batch]
                exporters: [file]
        '';
      };
    in
    {
      # The file exporter does not create its parent directory — ensure it
      # exists before the collector's first write attempt.
      home.activation.claudeOtelStateDir = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        /bin/mkdir -p ${lib.escapeShellArg (builtins.dirOf cfg.eventsFile)}
      '';

      launchd.agents.claude-otel-collector = {
        enable = true;
        config = {
          ProgramArguments = [
            (lib.getExe' pkgs.opentelemetry-collector-contrib "otelcol-contrib")
            "--config"
            "${otelConfig}"
          ];
          RunAtLoad = true;
          KeepAlive = true;
          StandardOutPath = "${config.home.homeDirectory}/Library/Logs/claude-otel-collector.log";
          StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/claude-otel-collector.log";
        };
      };
    }
  );
}
