# Every live object of the Grafana Cloud stack, adopted by `import` blocks (stack.nix) and
# GENERATED, not hand-written: `tofu plan -generate-config-out` over the live stack, then a
# deterministic HCL -> Nix conversion (2026-11-03, ADR-012 step 2). A `builtins.toJSON` value is
# exactly what the provider stores (rule models, the dashboard, datasource settings).
#
# Edit it like any Nix file. The plan is the judge: any change here shows up as a diff
# against the live stack. Per-person values arrive as arguments (identity.nix) or as the
# `rollup_sheet_id` tofu variable, never as literals.
{
  operatorEmail,
  gcpProjectId,
  publicSiteUrl,
}:
{
  grafana_contact_point = {
    operator_email = {
      disable_provenance = true;
      email = [
        {
          addresses = [
            operatorEmail
          ];
          single_email = true;
        }
      ];
      name = "operator-email";
      org_id = "0";
    };
  };
  grafana_dashboard = {
    evidence_pipeline = {
      config_json = builtins.toJSON {
        annotations = {
          list = [
            {
              builtIn = 1;
              datasource = {
                type = "grafana";
                uid = "-- Grafana --";
              };
              enable = true;
              hide = true;
              iconColor = "rgba(0, 211, 255, 1)";
              name = "Annotations & Alerts";
              type = "dashboard";
            }
          ];
        };
        editable = true;
        fiscalYearStartMonth = 0;
        graphTooltip = 0;
        links = [ ];
        panels = [
          {
            gridPos = {
              h = 3;
              w = 24;
              x = 0;
              y = 0;
            };
            options = {
              content = "Evidence store size, backlog and retrieval quality for **agentic-jobseek**, pushed over OTLP by `scripts/evidence-metrics.py` (store gauges on every `evidence-sync.sh`; quality points with `--eval`). Design: [ADR-0007 section 5, Monitoring](https://github.com/ismailkattakath/agentic-jobseek/blob/main/docs/adr/0007-evidence-review-at-point-of-use.md). Gauges are sparse, so every query uses `last_over_time` and a plateau means 'no newer sample', not 'steady'.";
              mode = "markdown";
            };
            title = "About";
            type = "text";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Documents per state file at the last sync.";
            fieldConfig = {
              defaults = {
                color = {
                  mode = "palette-classic";
                };
                min = 0;
                unit = "none";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 6;
              w = 8;
              x = 0;
              y = 3;
            };
            options = {
              displayMode = "gradient";
              orientation = "horizontal";
              reduceOptions = {
                calcs = [
                  "lastNotNull"
                ];
                values = false;
              };
              showUnfilled = true;
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "last_over_time(evidence_docs[30d])";
                instant = true;
                legendFormat = "{{status}}";
                range = false;
                refId = "A";
              }
            ];
            title = "Store size by status";
            type = "bargauge";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Age of the oldest pending document at the last sync. Green under 7 days, amber to 14, red beyond.";
            fieldConfig = {
              defaults = {
                color = {
                  mode = "thresholds";
                };
                decimals = 0;
                thresholds = {
                  mode = "absolute";
                  steps = [
                    {
                      color = "green";
                    }
                    {
                      color = "orange";
                      value = 7;
                    }
                    {
                      color = "red";
                      value = 14;
                    }
                  ];
                };
                unit = "d";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 6;
              w = 8;
              x = 8;
              y = 3;
            };
            options = {
              colorMode = "background";
              graphMode = "none";
              reduceOptions = {
                calcs = [
                  "lastNotNull"
                ];
                values = false;
              };
              textMode = "value";
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "last_over_time(evidence_pending_oldest_age_days[30d])";
                instant = true;
                range = false;
                refId = "A";
              }
            ];
            title = "Pending: oldest age (days)";
            type = "stat";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Now minus the newest run file's until_at. The routine is weekly: amber past 8 days, red past 10.";
            fieldConfig = {
              defaults = {
                color = {
                  mode = "thresholds";
                };
                thresholds = {
                  mode = "absolute";
                  steps = [
                    {
                      color = "green";
                    }
                    {
                      color = "orange";
                      value = 691200;
                    }
                    {
                      color = "red";
                      value = 864000;
                    }
                  ];
                };
                unit = "s";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 6;
              w = 8;
              x = 16;
              y = 3;
            };
            options = {
              colorMode = "background";
              graphMode = "none";
              reduceOptions = {
                calcs = [
                  "lastNotNull"
                ];
                values = false;
              };
              textMode = "value";
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "time() - last_over_time(evidence_last_discovery_until_seconds[30d])";
                instant = true;
                range = false;
                refId = "A";
              }
            ];
            title = "Last discovery run: age";
            type = "stat";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Retrieval quality per system (ADR-0004). One point per `evidence-metrics.py --eval`.";
            fieldConfig = {
              defaults = {
                custom = {
                  drawStyle = "line";
                  lineInterpolation = "stepAfter";
                  showPoints = "always";
                  spanNulls = true;
                };
                decimals = 3;
                max = 1;
                min = 0;
                unit = "none";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 8;
              w = 8;
              x = 0;
              y = 9;
            };
            options = {
              legend = {
                calcs = [
                  "lastNotNull"
                ];
                displayMode = "table";
                placement = "bottom";
              };
              tooltip = {
                mode = "multi";
              };
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "last_over_time(evidence_retrieval_ndcg_at_10[7d])";
                legendFormat = "{{system}}";
                range = true;
                refId = "A";
              }
            ];
            title = "nDCG@10 by system";
            type = "timeseries";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Share of graded-relevant documents in the top 10 (grade 1 or higher).";
            fieldConfig = {
              defaults = {
                custom = {
                  drawStyle = "line";
                  lineInterpolation = "stepAfter";
                  showPoints = "always";
                  spanNulls = true;
                };
                decimals = 3;
                max = 1;
                min = 0;
                unit = "none";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 8;
              w = 8;
              x = 8;
              y = 9;
            };
            options = {
              legend = {
                calcs = [
                  "lastNotNull"
                ];
                displayMode = "table";
                placement = "bottom";
              };
              tooltip = {
                mode = "multi";
              };
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "last_over_time(evidence_retrieval_recall_at_10[7d])";
                legendFormat = "{{system}}";
                range = true;
                refId = "A";
              }
            ];
            title = "Recall@10 by system";
            type = "timeseries";
          }
          {
            datasource = {
              type = "prometheus";
              uid = "grafanacloud-prom";
            };
            description = "Mean reciprocal rank of the first relevant document.";
            fieldConfig = {
              defaults = {
                custom = {
                  drawStyle = "line";
                  lineInterpolation = "stepAfter";
                  showPoints = "always";
                  spanNulls = true;
                };
                decimals = 3;
                max = 1;
                min = 0;
                unit = "none";
              };
              overrides = [ ];
            };
            gridPos = {
              h = 8;
              w = 8;
              x = 16;
              y = 9;
            };
            options = {
              legend = {
                calcs = [
                  "lastNotNull"
                ];
                displayMode = "table";
                placement = "bottom";
              };
              tooltip = {
                mode = "multi";
              };
            };
            targets = [
              {
                datasource = {
                  type = "prometheus";
                  uid = "grafanacloud-prom";
                };
                expr = "last_over_time(evidence_retrieval_mrr[7d])";
                legendFormat = "{{system}}";
                range = true;
                refId = "A";
              }
            ];
            title = "MRR by system";
            type = "timeseries";
          }
        ];
        refresh = "";
        schemaVersion = 42;
        tags = [
          "agentic-jobseek"
          "evidence"
        ];
        templating = {
          list = [ ];
        };
        time = {
          from = "now-7d";
          to = "now";
        };
        timepicker = { };
        timezone = "browser";
        title = "Evidence pipeline";
        uid = "evidence-pipeline";
        weekStart = "";
      };
      folder = "agentic-jobseek";
      message = null;
      org_id = "0";
      overwrite = null;
    };
  };
  grafana_data_source = {
    fleet_history = {
      access_mode = "proxy";
      basic_auth_enabled = false;
      http_headers = null;
      is_default = false;
      json_data_encoded = builtins.toJSON {
        authenticationType = "jwt";
        clientEmail = "grafana-sheets-reader@${gcpProjectId}.iam.gserviceaccount.com";
        defaultProject = gcpProjectId;
        defaultSheetID = "\${var.rollup_sheet_id}";
        tokenUri = "https://oauth2.googleapis.com/token";
      };
      name = "Fleet history (Sheet)";
      org_id = "1";
      private_data_source_connect_network_id = null;
      secure_json_data_encoded = null;
      type = "grafana-googlesheets-datasource";
      uid = "fleet-history";
    };
    github = {
      access_mode = "proxy";
      basic_auth_enabled = false;
      http_headers = null;
      is_default = false;
      json_data_encoded = builtins.toJSON {
        appId = "5588720";
        githubPlan = "github-basic";
        installationId = "178026813";
        selectedAuthType = "github-app";
      };
      name = "GitHub";
      org_id = "1";
      private_data_source_connect_network_id = null;
      secure_json_data_encoded = null;
      type = "grafana-github-datasource";
      uid = "github";
    };
  };
  grafana_folder = {
    agentic_jobseek = {
      org_id = "0";
      prevent_destroy_if_not_empty = null;
      title = "Agentic Jobseek";
      uid = "agentic-jobseek";
    };
    fleet = {
      org_id = "0";
      prevent_destroy_if_not_empty = null;
      title = "Fleet";
      uid = "fleet";
    };
  };
  grafana_notification_policy = {
    root = {
      contact_point = "operator-email";
      disable_provenance = true;
      group_by = [
        "grafana_folder"
        "alertname"
      ];
      org_id = "0";
    };
  };
  grafana_rule_group = {
    career = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "career";
      org_id = "1";
      rule = [
        {
          annotations = {
            description = "From agentic-jobseek's evidence-metrics funnel gauges (counts only). Weekly reminder, not a page.";
            summary = "Job search nudge: overdue next actions, or 7+ days since the last application";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "(max(last_over_time(jobseek_next_action_overdue[7d])) > 0) or (max(last_over_time(jobseek_days_since_last_application[7d])) > 7)";
                instant = true;
                refId = "A";
              };
              ref_id = "A";
              relative_time_range = [
                {
                  from = 604800;
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
            domain = "career";
            severity = "info";
          };
          missing_series_evals_to_resolve = 0;
          name = "Job search: follow-ups overdue or no application in 7 days";
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
          uid = "bg354l7tlo074e";
        }
      ];
    };
    fleet_health = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "fleet-health";
      org_id = "1";
      rule = [
        {
          annotations = {
            description = "Outside-in view; ICMP stayed green through the 2026-10 outage. Check the tunnel first (nixpi-liveness-probing), then Caddy.";
            summary = "snoringirl.com failing from most Synthetic Monitoring probes (Montreal, Calgary, Ohio)";
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
            description = "Fires until a backup exists (operator chose this knowingly, ADR-011 step 7).";
            summary = "The Mac has no Time Machine destination, or its last backup is older than 7 days";
          };
          condition = "C";
          data = [
            {
              datasource_uid = "grafanacloud-prom";
              model = builtins.toJSON {
                expr = "(max(last_over_time(mac_backup_destinations[26h])) == bool 0) or ((time() - max(last_over_time(mac_backup_last_success_timestamp_seconds[26h]))) > bool 604800)";
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
            domain = "infra";
            host = "macos";
            severity = "warning";
          };
          missing_series_evals_to_resolve = 0;
          name = "Mac backup missing or stale";
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
          uid = "bg353s2538wzkb";
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
      ];
    };
    free_tier = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "free-tier";
      org_id = "1";
      rule = [
        {
          annotations = {
            description = "Cut per ADR-011 § 5 (nix-config docs/observability-hub-adr.md): top consumers are nixpi node, Mac host_metrics, Caddy, cloudflared.";
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
    nixpi = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "nixpi";
      org_id = "1";
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
                expr = "max by (name) (node_systemd_unit_state{instance=\"nixpi\", state=\"active\", name=~\"(caddy|cloudflared-connector|audiobookshelf|alloy|avahi-daemon|sshd|supplicant-wlan0|dhcpcd)\\\\.service\"})";
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
      probes = [
        3
        44
        45
      ];
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
