# agentic-jobseek: its folder, the Evidence pipeline dashboard and the career rule group.
_: {
  grafana_folder = {
    agentic_jobseek = {
      prevent_destroy_if_not_empty = null;
      title = "Agentic Jobseek";
      uid = "agentic-jobseek";
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
  };
}
