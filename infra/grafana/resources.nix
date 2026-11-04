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
let
  # The units hosts/nixpi.nix ships; the alert watches the long-running ones only.
  # Imported by relative path, as infra/cloudflare/nixpi-tunnel.nix does derived-names.nix.
  nixpiUnits = (import ../../modules/_lib/nixpi-units.nix).longRunning;
  nixpiUnitRegex = "(${
    builtins.concatStringsSep "|" (map (u: builtins.replaceStrings [ ".service" ] [ "" ] u) nixpiUnits)
  })\\\\.service";

  # The canary matches with the SAME shapes Alloy's redact stage rewrites, so it can only
  # fire when that stage was not applied. IPv4 is left out: the shapes ADR-011 § 5 names
  # for this canary are MACs and IPv6. Each expr carries its own (?i), hoisted once here.
  leakShapes = builtins.concatStringsSep "|" (
    map (r: builtins.replaceStrings [ "(?i)" ] [ "" ] r.expr) (
      builtins.filter (
        r:
        builtins.elem r.name [
          "mac"
          "ipv6-full"
          "ipv6-compressed"
        ]
      ) (import ../../modules/_lib/log-redactions.nix)
    )
  );

  # One Grafana-managed rule in the generated rules' exact shape (query A, threshold C),
  # so a new rule is its distinct fields only. Explicit uids keep the plan free of churn.
  mkRule =
    {
      uid,
      name,
      summary,
      description,
      expr,
      op,
      threshold,
      for,
      labels,
      rangeSeconds ? 86400,
      datasource ? "grafanacloud-prom",
      repeat ? "1d",
    }:
    {
      annotations = { inherit description summary; };
      condition = "C";
      data = [
        {
          datasource_uid = datasource;
          model = builtins.toJSON {
            inherit expr;
            instant = true;
            refId = "A";
          };
          ref_id = "A";
          relative_time_range = [
            {
              from = rangeSeconds;
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
                  params = [ threshold ];
                  type = op;
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
      inherit
        for
        labels
        name
        uid
        ;
      is_paused = false;
      missing_series_evals_to_resolve = 0;
      no_data_state = "OK";
      notification_settings = [
        {
          active_timings = [ ];
          contact_point = "operator-email";
          group_by = [ ];
          mute_timings = [ ];
          repeat_interval = repeat;
        }
      ];
    };
in
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
      private_data_source_connect_network_id = null;
      secure_json_data_encoded = null;
      type = "grafana-github-datasource";
      uid = "github";
    };
  };
  grafana_folder = {
    agentic_jobseek = {
      prevent_destroy_if_not_empty = null;
      title = "Agentic Jobseek";
      uid = "agentic-jobseek";
    };
    fleet = {
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
    };
  };
  grafana_rule_group = {
    career = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "career";
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
          name = "healthchecks.io check new or down";
          summary = "healthchecks.io check {{ $labels.slug }} is new or down";
          description = "From hc_check_status (fleet-gauges, hourly). Paused checks and those in grace do not count. healthchecks.io emails on down itself; this catches a check that never pinged (new).";
          expr = "max by (slug) (last_over_time(hc_check_status{status=~\"new|down\"}[26h]))";
          op = "gt";
          threshold = 0;
          for = "26h0m0s";
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
      ];
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
