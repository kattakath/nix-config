# nixpi: its rule group (units, filesystem, SoC, the redaction canary) and the outside-in
# Synthetic Monitoring check of the public site.
{
  h,
  publicSiteUrl,
}:
let
  inherit (h)
    smProbeIds
    canary
    nixpiUnitRegex
    leakShapes
    mkRule
    ;
in
{
  grafana_rule_group = {
    nixpi = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "nixpi";
      rule = [
        {
          annotations = {
            description = "From Alloy's node_systemd_unit_state (ADR-011 step 4). Its journal: {service_name=\"nixpi-journal\"} | unit=\"{{ $labels.name }}\" in grafanacloud-logs.";
            summary = "nixpi unit {{ $labels.name }} is not active";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "max by (name) (node_systemd_unit_state{instance=\"nixpi\", state=\"active\", name=~\"${nixpiUnitRegex}\"})";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 600;
                  to = 0;
                }
              ];
            }
            {
              datasource_uid = "__expr__";
              model = builtins.toJSON {
                conditions = [
                  {
                    evaluator = {
                      params = [
                        1
                      ];
                      type = "lt";
                    };
                  }
                ];
                expression = "A";
                refId = "C";
                type = "threshold";
              };
              ref_id = "C";
              relative_time_range = [
                {
                  from = 0;
                  to = 0;
                }
              ];
            }
          ];
          exec_err_state = "Alerting";
          for = "5m0s";
          is_paused = false;
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "nixpi: service not active";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "12h";
            }
          ];
          uid = "fg34wq2wcbvggd";
        }
        {
          annotations = {
            description = "The 2026-10-01 failure shape: the SD card corrupted, the tunnel stayed up. See docs/nixpi-sd-flashing-runbook.md.";
            summary = "nixpi rootfs remounted read-only (errors=remount-ro)";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "max(node_filesystem_readonly{instance=\"nixpi\", mountpoint=\"/\"})";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 600;
                  to = 0;
                }
              ];
            }
            {
              datasource_uid = "__expr__";
              model = builtins.toJSON {
                conditions = [
                  {
                    evaluator = {
                      params = [
                        0
                      ];
                      type = "gt";
                    };
                  }
                ];
                expression = "A";
                refId = "C";
                type = "threshold";
              };
              ref_id = "C";
              relative_time_range = [
                {
                  from = 0;
                  to = 0;
                }
              ];
            }
          ];
          exec_err_state = "Alerting";
          for = "2m0s";
          is_paused = false;
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "critical";
          };
          missing_series_evals_to_resolve = 0;
          name = "nixpi: root filesystem read-only";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "6h";
            }
          ];
          uid = "dg34wqbapje9sc";
        }
        {
          annotations = {
            description = "Value 100 means silence: Alloy is down or the token was lost. The healthchecks.io nixpi-serving check covers 'site down'.";
            summary = "nixpi SoC above 75 C (throttles at 80), or no node metrics for 15 min";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "(max(node_thermal_zone_temp{instance=\"nixpi\"}) > 75) or (absent_over_time(node_uname_info{instance=\"nixpi\"}[15m]) * 100)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 1800;
                  to = 0;
                }
              ];
            }
            {
              datasource_uid = "__expr__";
              model = builtins.toJSON {
                conditions = [
                  {
                    evaluator = {
                      params = [
                        0
                      ];
                      type = "gt";
                    };
                  }
                ];
                expression = "A";
                refId = "C";
                type = "threshold";
              };
              ref_id = "C";
              relative_time_range = [
                {
                  from = 0;
                  to = 0;
                }
              ];
            }
          ];
          exec_err_state = "Alerting";
          for = "10m0s";
          is_paused = false;
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "nixpi: SoC hot or telemetry silent";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "12h";
            }
          ];
          uid = "eg34wqldz9slcb";
        }
        (mkRule {
          uid = "nixpi-canary-unredacted";
          name = "nixpi: redaction canary arrived unredacted";
          summary = "The daily redaction canary reached Loki with a planted address intact: the redact stage is not running";
          description = "modules/_lib/redaction-canary.nix plants reserved addresses in one WARNING line a day; this matches any of them verbatim.";
          datasource = "grafanacloud-logs";
          expr = "sum(count_over_time({service_name=\"nixpi-journal\"} |= `${canary.marker}` |~ `${builtins.concatStringsSep "|" canary.values}` [26h]))";
          rangeSeconds = 93600;
          op = "gt";
          threshold = 0;
          for = "0s";
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "critical";
          };
        })
        (mkRule {
          uid = "nixpi-canary-missing";
          name = "nixpi: redaction canary missing";
          summary = "No redaction canary line from nixpi in 26 h: journal shipping (or its timer) is broken";
          description = "The redaction-canary timer logs one line a day; `or vector(0)` makes its absence a 0 rather than no data.";
          datasource = "grafanacloud-logs";
          expr = "sum(count_over_time({service_name=\"nixpi-journal\"} |= `${canary.marker}` [26h])) or vector(0)";
          rangeSeconds = 93600;
          op = "lt";
          threshold = 1;
          for = "1h";
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "nixpi-redaction-canary";
          name = "nixpi: journal redaction gap";
          summary = "{{ $values.A }} nixpi journal line(s) in the last hour still carry a MAC or IPv6 address";
          description = "Same shapes as Alloy's redact stage (modules/_lib/log-redactions.nix), so this means the stage was not applied, not that a shape is missing. Find them: {service_name=\"nixpi-journal\"} |~ the rule's regex, in grafanacloud-logs.";
          datasource = "grafanacloud-logs";
          expr = "sum(count_over_time({service_name=\"nixpi-journal\"} |~ `(?i)(?:${leakShapes})` [1h]))";
          rangeSeconds = 3600;
          op = "gt";
          threshold = 0;
          for = "0s";
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "warning";
          };
        })
      ];
    };
  };
  grafana_synthetic_monitoring_check = {
    public_site = {
      alert_sensitivity = "";
      basic_metrics_only = true;
      enabled = true;
      frequency = 300000;
      job = "nixpi-public-site";
      labels = {
        domain = "infra";
        host = "nixpi";
      };
      probes = smProbeIds;
      settings = [
        {
          http = [
            {
              fail_if_not_ssl = true;
              fail_if_ssl = false;
              ip_version = "V4";
              method = "GET";
              valid_status_codes = [
                200
              ];
            }
          ];
        }
      ];
      target = publicSiteUrl;
      timeout = 10000;
    };
  };
}
