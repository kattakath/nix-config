# Grafana Alloy shipping a NixOS host's metrics and WARN+ journal to Grafana Cloud
# over OTLP/HTTP (ADR-011, docs/observability-hub-adr.md § 3).
#
# upstream-first: nixpkgs' `services.alloy` (nixos/modules/services/monitoring/alloy.nix)
# owns the unit, the DynamicUser and the systemd-journal group. This module only writes
# the config and adds the three things that module does not cover:
#   * the WAL and journal positions go to /run (`--storage.path`), never the default
#     WorkingDirectory %S/alloy — on an SD-card host every byte written there is wear;
#   * the credential arrives as an EnvironmentFile (endpoint, instance id, token), so no
#     per-person value or secret sits in the store or the repo;
#   * the unit only starts when that file exists (ConditionPathExists): a host flashed
#     without it simply ships nothing, instead of crash-looping into the journal.
{ config, lib, ... }:
let
  cfg = config.local.alloyShipper;
  # RE2, fully anchored by node_exporter: one alternation, never a substring match.
  # Backslashes doubled: the regex sits inside an Alloy string literal.
  unitRegex =
    lib.replaceStrings [ "\\" ] [ "\\\\" ]
      "(${lib.concatStringsSep "|" (map lib.escapeRegex cfg.systemdUnits)})";
in
{
  options.local.alloyShipper = {
    enable = lib.mkEnableOption "Grafana Alloy shipping host metrics and WARN+ journal lines to Grafana Cloud";

    environmentFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/grafana-alloy.env";
      description = ''
        Root-only file holding GRAFANA_OTLP_ENDPOINT, GRAFANA_OTLP_INSTANCE and
        GRAFANA_OTLP_TOKEN. Alloy does not start while it is absent.
      '';
    };

    systemdUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "caddy.service" ];
      description = ''
        Units whose state is exported (node_systemd_unit_state). An ALLOWLIST: each
        unit costs 5 series, and a blanket list would track every oneshot.
      '';
    };

    dropJournalUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "supplicant-wlan0.service" ];
      description = ''
        Units whose journal lines never leave the host, whatever their priority —
        for logs that name networks or devices (ADR-011 § 5).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.alloy = {
      enable = true;
      extraFlags = [
        "--storage.path=/run/alloy"
        "--server.http.listen-addr=127.0.0.1:12345"
        "--disable-reporting"
      ];
    };

    systemd.services.alloy = {
      unitConfig.ConditionPathExists = cfg.environmentFile;
      serviceConfig = {
        RuntimeDirectory = "alloy";
        EnvironmentFile = [ cfg.environmentFile ];
      };
    };

    environment.etc."alloy/config.alloy".text = ''
      // ---- metrics: node exporter, allowlisted to what ADR-011 § 6 step 4 names ----
      prometheus.exporter.unix "node" {
        set_collectors = ["cpu", "meminfo", "loadavg", "pressure", "filesystem", "diskstats",
                          "netdev", "hwmon", "thermal_zone", "systemd", "btrfs", "time", "uname"]
        filesystem {
          fs_types_exclude = "^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|nsfs|overlay|proc|pstore|ramfs|rpc_pipefs|securityfs|sysfs|tmpfs|tracefs)$"
        }
        netdev {
          device_exclude = "^(lo|zram.*)$"
        }
        disk {
          device_exclude = "^(zram|loop|ram).*$"
        }
        systemd {
          unit_include = "${unitRegex}"
        }
      }

      prometheus.scrape "node" {
        targets         = prometheus.exporter.unix.node.targets
        job_name        = "node"
        scrape_interval = "60s"
        forward_to      = [otelcol.receiver.prometheus.default.receiver]
      }

      // Alloy's own health: is it exporting, and is the exporter failing?
      prometheus.exporter.self "alloy" { }

      prometheus.scrape "self" {
        targets         = prometheus.exporter.self.alloy.targets
        job_name        = "alloy"
        scrape_interval = "60s"
        forward_to      = [prometheus.relabel.self.receiver]
      }

      prometheus.relabel "self" {
        rule {
          source_labels = ["__name__"]
          regex         = "alloy_build_info|otelcol_exporter_sent_.*|otelcol_exporter_send_failed_.*|loki_source_journal_target_lines_total"
          action        = "keep"
        }
        forward_to = [otelcol.receiver.prometheus.default.receiver]
      }

      otelcol.receiver.prometheus "default" {
        output {
          metrics = [otelcol.processor.batch.default.input]
        }
      }

      // ---- logs: journald, WARNING and worse only (priorities 0-4) ----
      loki.relabel "journal" {
        forward_to = []
        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }
        rule {
          source_labels = ["__journal_priority_keyword"]
          target_label  = "level"
        }
      }

      loki.source.journal "journal" {
        max_age       = "12h"
        matches       = "PRIORITY=0 PRIORITY=1 PRIORITY=2 PRIORITY=3 PRIORITY=4"
        relabel_rules = loki.relabel.journal.rules
        labels        = {job = "journal"}
        forward_to    = [loki.process.redact.receiver]
      }

      // ADR-011 § 5: no client IPs, MACs or network names leave the host.
      loki.process "redact" {
        ${lib.concatMapStrings (u: ''
          stage.match {
            selector = "{unit=\"${u}\"}"
            action   = "drop"
          }
        '') cfg.dropJournalUnits}
        stage.replace {
          expression = "(\\b\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\b)"
          replace    = "<ip>"
        }
        stage.replace {
          expression = "(?i)(\\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}\\b)"
          replace    = "<ip6-or-mac>"
        }
        forward_to = [otelcol.receiver.loki.default.receiver]
      }

      otelcol.receiver.loki "default" {
        output {
          logs = [otelcol.processor.transform.journal.input]
        }
      }

      // Without a resource service.name, Grafana Cloud files every line under
      // service_name="unknown_service" (measured 2026-11-03). One name per host keeps
      // the stream count at one; the unit stays per-line structured metadata, queried
      // as {service_name="<host>-journal"} | unit="caddy.service".
      otelcol.processor.transform "journal" {
        error_mode = "ignore"
        log_statements {
          context    = "resource"
          statements = [`set(attributes["service.name"], "${config.networking.hostName}-journal")`]
        }
        output {
          logs = [otelcol.processor.batch.default.input]
        }
      }

      // ---- export: one OTLP gateway, one credential, both signals ----
      otelcol.processor.batch "default" {
        output {
          metrics = [otelcol.exporter.otlphttp.grafana.input]
          logs    = [otelcol.exporter.otlphttp.grafana.input]
        }
      }

      otelcol.auth.basic "grafana" {
        username = sys.env("GRAFANA_OTLP_INSTANCE")
        password = sys.env("GRAFANA_OTLP_TOKEN")
      }

      otelcol.exporter.otlphttp "grafana" {
        client {
          endpoint = sys.env("GRAFANA_OTLP_ENDPOINT")
          auth     = otelcol.auth.basic.grafana.handler
        }
      }
    '';
  };
}
