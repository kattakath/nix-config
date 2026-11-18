# The fleet's own board and rule groups: the Fleet overview dashboard, the fleet-health
# group (gauges, CI, credentials, the Mac) and the free-tier group. The add-on's panels
# and rule are appended from addon.nix.
{
  h,
  addon,
}:
let
  inherit (h)
    publicSiteHost
    smProbeCities
    macDiskFreePct
    fleetStat
    fleetSeries
    mkRule
    ;
in
{
  grafana_dashboard = {
    # One screen over what already arrives: the top row is the alert rules' own
    # expressions as counts, so the board and the alerts cannot disagree.
    fleet_overview = {
      config_json = builtins.toJSON {
        editable = true;
        graphTooltip = 1;
        links = [ ];
        panels = [
          (fleetStat {
            title = "Heartbeats down";
            expr = "count(max by (slug) (last_over_time(hc_check_overdue[2h])) > 0) or vector(0)";
            x = 0;
            y = 0;
          })
          (fleetStat {
            title = "Workflows failing";
            expr = "count(min by (repo, workflow) (last_over_time(github_workflow_last_conclusion_ok[26h])) < 1) or vector(0)";
            x = 4;
            y = 0;
          })
          (fleetStat {
            title = "Stacks drifted";
            description = "0/1/2 = clean/drift/error per terranix stack, from the daily drift check.";
            expr = "count(max by (stack) (last_over_time(terranix_drift_status[26h])) > 0) or vector(0)";
            x = 8;
            y = 0;
          })
          (fleetStat {
            title = "Doctor findings";
            description = "From the latest published /hygiene and /fleet-doctor runs; it changes only when a doctor runs.";
            expr = "sum(max by (doctor) (last_over_time(doctor_findings[26h]))) or vector(0)";
            x = 12;
            y = 0;
          })
          (fleetStat {
            title = "Unarmed pull requests";
            expr = "sum(max by (owner) (last_over_time(github_unarmed_prs[26h]))) or vector(0)";
            x = 16;
            y = 0;
          })
          (fleetStat {
            title = "launchd findings";
            expr = "sum(max by (section) (last_over_time(launchd_doctor_findings[26h]))) or vector(0)";
            x = 20;
            y = 0;
          })
          (fleetSeries {
            title = "Open security alerts";
            expr = "sum by (owner, kind) (last_over_time(github_security_open_alerts[26h]))";
            legend = "{{owner}} {{kind}}";
            x = 0;
            y = 4;
          })
          (fleetSeries {
            title = "Mac: free space on the Data volume";
            description = "The alert line is 10%.";
            expr = macDiskFreePct;
            legend = "free";
            unit = "percent";
            x = 12;
            y = 4;
          })
          (fleetSeries {
            title = "Mac: load average (1 m)";
            expr = ''max(system_cpu_load_average_1m{service_name="macos-host"})'';
            legend = "load";
            x = 0;
            y = 12;
          })
          (fleetSeries {
            title = "nixpi: SoC temperature";
            expr = ''max(node_thermal_zone_temp{instance="nixpi"})'';
            legend = "SoC";
            unit = "celsius";
            x = 12;
            y = 12;
          })
          (fleetSeries {
            title = "Claude Code: cost per day";
            expr = "sum(increase(claude_code_cost_usage_USD_total[1d]))";
            legend = "USD";
            unit = "currencyUSD";
            x = 0;
            y = 20;
          })
          (fleetSeries {
            title = "Claude Code: tokens per day by type";
            expr = "sum by (type) (increase(claude_code_token_usage_tokens_total[1d]))";
            legend = "{{type}}";
            x = 12;
            y = 20;
          })
        ]
        ++ addon.panels;
        refresh = "";
        schemaVersion = 42;
        tags = [ "fleet" ];
        templating.list = [ ];
        time = {
          from = "now-7d";
          to = "now";
        };
        timezone = "browser";
        title = "Fleet overview";
        uid = "fleet-overview";
      };
      folder = "fleet";
      message = null;
      overwrite = null;
    };
  };
  grafana_rule_group = {
    fleet_health = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "fleet-health";
      rule = [
        {
          annotations = {
            description = "Outside-in view; ICMP stayed green through the 2026-10 outage. Check the tunnel first (nixpi-liveness-probing), then Caddy.";
            summary = "${publicSiteHost} failing from most Synthetic Monitoring probes (${smProbeCities})";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "avg(avg_over_time(probe_success{job=\"nixpi-public-site\"}[10m]))";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 900;
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
                        0.5
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
            severity = "critical";
          };
          missing_series_evals_to_resolve = 0;
          name = "Public site down from outside";
          no_data_state = "Alerting";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "6h";
            }
          ];
          uid = "fg353r9p1dhq8a";
        }
        {
          annotations = {
            description = "Sources: fleet_credential_expiry_timestamp_seconds (packages/fleet-gauges.nix) and probe_ssl_earliest_cert_expiry.";
            summary = "A fleet credential or the public TLS certificate expires in under 14 days ({{ $values.A }} d)";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "min((last_over_time(fleet_credential_expiry_timestamp_seconds[26h]) - time()) / 86400) or min((probe_ssl_earliest_cert_expiry{job=\"nixpi-public-site\"} - time()) / 86400)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 86400;
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
                        14
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
          for = "1h0m0s";
          is_paused = false;
          labels = {
            domain = "infra";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "Credential or TLS certificate expires within 14 days";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "1d";
            }
          ];
          uid = "ag353rk641ou8e";
        }
        {
          annotations = {
            description = "Counted hourly by fleet-gauges across public non-fork repos. Triage at github.com/<owner>/<repo>/security.";
            summary = "{{ $labels.owner }}: {{ $values.A }} open {{ $labels.kind }} alert(s)";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "sum by (owner, kind) (last_over_time(github_security_open_alerts[26h]))";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 86400;
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
          for = "1h0m0s";
          is_paused = false;
          labels = {
            domain = "ci";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "Open GitHub security alerts";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "1w";
            }
          ];
          uid = "bg353rsjiamtcf";
        }
        {
          annotations = {
            description = "Check ~/Library/Logs/fleet-gauges.log and launchctl print gui/$UID/org.nix-community.home.fleet-gauges.";
            summary = "No fleet-gauges push for {{ $values.A }} h (it runs hourly while the Mac is awake)";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "(time() - max(last_over_time(fleet_gauges_last_run_timestamp_seconds[2d]))) / 3600 or vector(999)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 172800;
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
                        26
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
          for = "30m0s";
          is_paused = false;
          labels = {
            domain = "infra";
            host = "macos";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "fleet-gauges stopped reporting";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "1d";
            }
          ];
          uid = "dg353sam3ckxse";
        }
        (mkRule {
          uid = "fleet-hc-status";
          name = "healthchecks.io check down or overdue";
          summary = "healthchecks.io check {{ $labels.slug }} is down, or never pinged past its first due time";
          description = "From hc_check_overdue (fleet-gauges, hourly): down, or still new after its first ping was due (first seen + period or next cron fire + grace), so a just-created weekly check does not page. healthchecks.io emails on down itself; this catches a pinger that never pinged.";
          expr = "max by (slug) (last_over_time(hc_check_overdue[2h]))";
          op = "gt";
          threshold = 0;
          for = "1h0m0s";
          labels = {
            domain = "infra";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "fleet-gauges-source-errors";
          name = "fleet-gauges source failing";
          summary = "fleet-gauges source {{ $labels.source }} has errored for 26 h";
          description = "One source failing every run; its gauges are missing. The reason is in ~/Library/Logs/fleet-gauges.log.";
          expr = "max by (source) (last_over_time(fleet_gauges_source_errors[26h]))";
          op = "gt";
          threshold = 0;
          for = "26h0m0s";
          labels = {
            domain = "infra";
            host = "macos";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "fleet-launchd-doctor";
          name = "launchd-doctor findings";
          summary = "launchd-doctor: {{ $values.A }} finding(s) in {{ $labels.section }}";
          description = "Run `nix run .#launchd-doctor` on the Mac for the remedies; it is read-only.";
          expr = "max by (section) (last_over_time(launchd_doctor_findings[26h]))";
          op = "gt";
          threshold = 0;
          for = "2h0m0s";
          labels = {
            domain = "infra";
            host = "macos";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "fleet-workflow-failing";
          name = "GitHub workflow failing on main";
          summary = "{{ $labels.repo }}: workflow {{ $labels.workflow }} failed its latest main run";
          description = "From github_workflow_last_conclusion_ok (fleet-gauges, latest completed main-branch run per workflow).";
          expr = "min by (repo, workflow) (last_over_time(github_workflow_last_conclusion_ok[26h]))";
          op = "lt";
          threshold = 1;
          for = "2h0m0s";
          labels = {
            domain = "ci";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "fleet-sd-image-stale";
          name = "nixpi SD image release older than 30 days";
          summary = "The installer-latest nixpi SD image is {{ $values.A }} days old";
          description = "build-installers.yml republishes it when the nixpi closure changes; an old asset means a reflash would boot a stale generation.";
          expr = "max(last_over_time(nixpi_sd_release_age_seconds[26h])) / 86400";
          op = "gt";
          threshold = 30;
          for = "1h0m0s";
          labels = {
            domain = "infra";
            host = "nixpi";
            severity = "info";
          };
          repeat = "1w";
        })
        (mkRule {
          uid = "fleet-doctor-findings";
          name = "Doctor findings open";
          summary = "{{ $labels.doctor }}: {{ $values.A }} finding(s) in its latest report";
          description = "From doctor_findings (fleet-gauges, hourly), read from the latest published /hygiene or /fleet-doctor run. The count changes only when that doctor runs again, so re-run it after a fix. Reports: ~/.local/state/nix-config-doctors.";
          expr = "max by (doctor) (last_over_time(doctor_findings[26h]))";
          op = "gt";
          threshold = 0;
          for = "2h0m0s";
          labels = {
            domain = "infra";
            severity = "info";
          };
          repeat = "1w";
        })
        (mkRule {
          uid = "fleet-unarmed-prs";
          name = "Pull requests open with no auto-merge armed";
          summary = "{{ $labels.owner }}: {{ $values.A }} pull request(s) open over 8 h with no auto-merge armed";
          description = "From github_unarmed_prs (fleet-gauges, hourly): non-draft PRs in repos that carry auto-merge.yml. The arming workflows run on a schedule, so a count here means one did not arm, or a PR was opened by hand and left. Draft it, arm it or close it.";
          expr = "max by (owner) (last_over_time(github_unarmed_prs[26h]))";
          op = "gt";
          threshold = 0;
          for = "2h0m0s";
          labels = {
            domain = "ci";
            severity = "info";
          };
          repeat = "1w";
        })
        (mkRule {
          uid = "fleet-mac-disk-free";
          name = "Mac: under 10% free on the Data volume";
          summary = "The Mac's Data volume has {{ printf \"%.1f\" $values.A.Value }}% free";
          description = "From the collector's hostmetrics (service_name macos-host). APFS volumes share the container, so this is the container's free space. Same line as fleet-doctor's FD-E-disk-free.";
          expr = macDiskFreePct;
          op = "lt";
          threshold = 10;
          # 6 h, not 1 h: the live value sits near the line, and a short `for` would flap.
          for = "6h0m0s";
          labels = {
            domain = "infra";
            host = "macos";
            severity = "warning";
          };
        })
      ]
      ++ addon.rules;
    };
    free_tier = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "free-tier";
      rule = [
        {
          annotations = {
            description = "Cut per ADR-011 § 5 (nix-config docs/observability-hub-adr.md): top consumers are nixpi node_exporter (Alloy), Mac hostmetrics and Claude Code metrics (both via claude-otel).";
            summary = "Grafana Cloud active series above 70% of the free 10k";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-usage";
              model = builtins.toJSON {
                expr = "max(grafanacloud_org_metrics_billable_series) / max(grafanacloud_org_metrics_included_series)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 3600;
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
                        0.7
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
          for = "1h0m0s";
          is_paused = false;
          labels = {
            domain = "saas-cost";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "Free tier: active series over 70%";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "1d";
            }
          ];
          uid = "fg34rivwd1f5se";
        }
        {
          annotations = {
            description = "Check ADR-011 § 5 volume bombs: unified log, unfiltered Claude logs, journald debug lines.";
            summary = "Grafana Cloud log ingest above 70% of the free 50 GB";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-usage";
              model = builtins.toJSON {
                expr = "max(grafanacloud_org_logs_usage) / max(grafanacloud_org_logs_included_usage)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 3600;
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
                        0.7
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
          for = "1h0m0s";
          is_paused = false;
          labels = {
            domain = "saas-cost";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "Free tier: logs over 70%";
          no_data_state = "OK";
          notification_settings = [
            {
              active_timings = [ ];
              contact_point = "operator-email";
              group_by = [ ];
              mute_timings = [ ];
              repeat_interval = "1d";
            }
          ];
          uid = "ag34rj3px3e9sa";
        }
      ];
    };
  };
}
