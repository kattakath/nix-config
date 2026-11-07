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
  # The public site's host, from the same hostedSites entry the probe targets.
  publicSiteHost = builtins.head (builtins.match "https://([^/]+)/" publicSiteUrl);
  # The Synthetic Monitoring probes public_site runs from, and their cities for the alert
  # text, side by side so a probe change edits both.
  smProbeIds = [
    3
    44
    45
  ];
  smProbeCities = "Montreal, Calgary, Ohio";
  # The units hosts/nixpi.nix ships; the alert watches the long-running ones only.
  # Imported by relative path, as infra/cloudflare/nixpi-tunnel.nix does derived-names.nix.
  nixpiUnits = (import ../../modules/_lib/nixpi-units.nix).longRunning;
  # The planted line (ADR-013); its values carry no regex metacharacters, so they join as-is.
  canary = import ../../modules/_lib/redaction-canary.nix;
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

  # ---- Google Maps Platform usage, read on demand from Cloud Monitoring ----
  # Datasource `gcp-monitoring` (stock `stackdriver` plugin) queries the project's Cloud
  # Monitoring with PromQL, so none of this costs a Grafana series. Every Maps Platform API
  # reports `serviceruntime.googleapis.com/api/request_count` on the `consumed_api` resource;
  # the `*-backend` services are the legacy Maps web services (geocoding-, places-,
  # directions-, distance-matrix-, elevation-, timezone-, maps-, static-maps-backend), the
  # rest are the newer Maps APIs. Windows are FIXED ([10m], [1d], [30d]): `$__interval`
  # does not reach alert evaluation, which runs in the backend.
  mapsDatasource = "gcp-monitoring";
  mapsServiceRe = builtins.concatStringsSep "|" [
    ".*-backend\\\\.googleapis\\\\.com"
    "places\\\\.googleapis\\\\.com"
    "routes\\\\.googleapis\\\\.com"
    "addressvalidation\\\\.googleapis\\\\.com"
    "geolocation\\\\.googleapis\\\\.com"
    "roads\\\\.googleapis\\\\.com"
  ];
  mapsReq =
    extra:
    ''serviceruntime_googleapis_com:api_request_count{monitored_resource="consumed_api",service=~"${mapsServiceRe}"${extra}}'';
  geocodeSel = ''monitored_resource="consumed_api",service="geocoding-backend.googleapis.com"'';
  # quota_limit is written sparsely, so a bare selector is stale (empty) most of the time
  # (measured 2026-11-07); last_over_time over a day always finds the latest value.
  geocodeDailyLimit = ''max(last_over_time(serviceruntime_googleapis_com:quota_limit{monitored_resource="consumer_quota",service="geocoding-backend.googleapis.com",limit_name="BillableDefaultPerDayPerProject"}[1d]))'';
  # Geocoding is an Essentials SKU: 10,000 free calls a month, then 5 USD per 1,000
  # (https://developers.google.com/maps/billing-and-pricing/pricing, since 2025-03-01).
  # The 300/day quota in infra/gcp/foundation.nix keeps a 31-day month at 9,300.
  geocodeFreePerMonth = 10000;
  geocodeUsdPerCall = 0.005;
  mapsQuery = expr: {
    queryType = "promQL";
    promQLQuery = {
      projectName = gcpProjectId;
      inherit expr;
      step = "60s";
    };
  };
  mapsTarget =
    refId: expr:
    (mapsQuery expr)
    // {
      datasource = {
        type = "stackdriver";
        uid = mapsDatasource;
      };
      inherit refId;
    };
  mapsPanel =
    {
      title,
      type,
      description,
      gridPos,
      targets,
      unit ? "none",
      thresholds ? null,
      extraDefaults ? { },
      options ? { },
    }:
    {
      datasource = {
        type = "stackdriver";
        uid = mapsDatasource;
      };
      inherit
        title
        type
        description
        gridPos
        targets
        options
        ;
      fieldConfig = {
        defaults = {
          inherit unit;
          min = 0;
        }
        // extraDefaults
        // (
          if thresholds == null then
            { }
          else
            {
              color.mode = "thresholds";
              thresholds = {
                mode = "absolute";
                steps = thresholds;
              };
            }
        );
        overrides = [ ];
      };
    };

  # One Grafana-managed rule in the generated rules' exact shape (query A, threshold C),
  # so a new rule is its distinct fields only. Explicit uids keep the plan free of churn.
  mkRule =
    {
      uid,
      name,
      summary,
      description,
      expr ? null,
      op,
      threshold,
      for,
      labels,
      rangeSeconds ? 86400,
      datasource ? "grafanacloud-prom",
      repeat ? "1d",
      # The query model; a non-Prometheus datasource passes its own shape here.
      model ? {
        inherit expr;
        instant = true;
      },
      # Insert a reduce node B (last value) between A and the threshold. Needed by a
      # datasource whose backend only answers range queries: the stackdriver plugin calls
      # query_range alone, and Grafana refuses to alert on a series that is not reduced.
      reduce ? false,
    }:
    # The default model with no expr would render `"expr": null` and evaluate nothing.
    assert (model.expr or "") != null;
    {
      annotations = { inherit description summary; };
      condition = "C";
      data = [
        {
          datasource_uid = datasource;
          model = builtins.toJSON (model // { refId = "A"; });
          ref_id = "A";
          relative_time_range = [
            {
              from = rangeSeconds;
              to = 0;
            }
          ];
        }
      ]
      ++ builtins.filter (_: reduce) [
        {
          datasource_uid = "__expr__";
          model = builtins.toJSON {
            expression = "A";
            reducer = "last";
            refId = "B";
            settings.mode = "dropNN";
            type = "reduce";
          };
          ref_id = "B";
          relative_time_range = [
            {
              from = 0;
              to = 0;
            }
          ];
        }
      ]
      ++ [
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
            expression = if reduce then "B" else "A";
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
    maps_platform = {
      config_json = builtins.toJSON {
        editable = true;
        graphTooltip = 1;
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
              content = "Google Maps Platform calls in GCP project **${gcpProjectId}**, read live from Cloud Monitoring (`serviceruntime.googleapis.com/api/request_count` on `consumed_api`) by the `gcp-monitoring` datasource: no Grafana series are stored. Geocoding is capped at its daily quota (infra/gcp/foundation.nix), which keeps a month under the 10,000 free calls, so the cost panel should read 0. Rolling 24 h windows do not line up with the quota's reset at midnight Pacific time.";
              mode = "markdown";
            };
            title = "About";
            type = "text";
          }
          (mapsPanel {
            title = "Geocoding: last 24 h vs daily quota";
            type = "gauge";
            description = "Rolling 24 h geocoding requests as a share of the BillableDefaultPerDayPerProject quota limit, read live from Cloud Monitoring.";
            gridPos = {
              h = 6;
              w = 6;
              x = 0;
              y = 3;
            };
            unit = "percentunit";
            extraDefaults.max = 1;
            thresholds = [
              {
                color = "green";
                value = null;
              }
              {
                color = "orange";
                value = 0.8;
              }
              {
                color = "red";
                value = 0.95;
              }
            ];
            targets = [
              (mapsTarget "A" "sum(increase(serviceruntime_googleapis_com:api_request_count{${geocodeSel}}[1d])) / ${geocodeDailyLimit}")
            ];
            options.reduceOptions.calcs = [ "lastNotNull" ];
          })
          (mapsPanel {
            title = "Maps requests, last 24 h";
            type = "stat";
            description = "All Maps Platform APIs, rolling 24 h.";
            gridPos = {
              h = 6;
              w = 6;
              x = 6;
              y = 3;
            };
            targets = [ (mapsTarget "A" "sum(increase(${mapsReq ""}[1d]))") ];
            options.reduceOptions.calcs = [ "lastNotNull" ];
          })
          (mapsPanel {
            title = "Geocoding, last 30 days vs free tier";
            type = "gauge";
            description = "Rolling 30 days approximates the billing month. ${toString geocodeFreePerMonth} Essentials calls a month are free.";
            gridPos = {
              h = 6;
              w = 6;
              x = 12;
              y = 3;
            };
            extraDefaults.max = geocodeFreePerMonth;
            thresholds = [
              {
                color = "green";
                value = null;
              }
              {
                color = "orange";
                value = geocodeFreePerMonth * 0.8;
              }
              {
                color = "red";
                value = geocodeFreePerMonth;
              }
            ];
            targets = [
              (mapsTarget "A" "sum(increase(serviceruntime_googleapis_com:api_request_count{${geocodeSel}}[30d]))")
            ];
            options.reduceOptions.calcs = [ "lastNotNull" ];
          })
          (mapsPanel {
            title = "Geocoding: estimated cost, last 30 days";
            type = "stat";
            description = "max(0, calls - ${toString geocodeFreePerMonth}) x ${toString geocodeUsdPerCall} USD. An estimate from request counts, not the bill; the 5 CAD budget (infra/gcp/budget.nix) is the billing-side alert.";
            gridPos = {
              h = 6;
              w = 6;
              x = 18;
              y = 3;
            };
            unit = "currencyUSD";
            thresholds = [
              {
                color = "green";
                value = null;
              }
              {
                color = "red";
                value = 0.01;
              }
            ];
            targets = [
              (mapsTarget "A" "clamp_min(sum(increase(serviceruntime_googleapis_com:api_request_count{${geocodeSel}}[30d])) - ${toString geocodeFreePerMonth}, 0) * ${toString geocodeUsdPerCall}")
            ];
            options.reduceOptions.calcs = [ "lastNotNull" ];
          })
          (mapsPanel {
            title = "Requests per minute by API, method and response class";
            type = "timeseries";
            description = "rate over 10 m, x 60.";
            gridPos = {
              h = 9;
              w = 24;
              x = 0;
              y = 9;
            };
            unit = "reqpm";
            targets = [
              (mapsTarget "A" "sum by (service, method, response_code_class) (rate(${mapsReq ""}[10m])) * 60")
            ];
          })
          (mapsPanel {
            title = "Error ratio (non-2xx) by API";
            type = "timeseries";
            description = "Share of calls that did not return 2xx, over 1 h. A 429 here usually means the daily quota cap was hit.";
            gridPos = {
              h = 8;
              w = 12;
              x = 0;
              y = 18;
            };
            unit = "percentunit";
            targets = [
              (mapsTarget "A" "sum by (service) (increase(${mapsReq '',response_code_class!="2xx"''}[1h])) / sum by (service) (increase(${mapsReq ""}[1h]))")
            ];
          })
          (mapsPanel {
            title = "Latency p50 / p95 by API";
            type = "timeseries";
            description = "serviceruntime request_latencies, as seen by Google's front end.";
            gridPos = {
              h = 8;
              w = 12;
              x = 12;
              y = 18;
            };
            unit = "s";
            targets = [
              (mapsTarget "A" ''histogram_quantile(0.5, sum by (service, le) (rate(serviceruntime_googleapis_com:api_request_latencies_bucket{monitored_resource="consumed_api",service=~"${mapsServiceRe}"}[1h])))'')
              (mapsTarget "B" ''histogram_quantile(0.95, sum by (service, le) (rate(serviceruntime_googleapis_com:api_request_latencies_bucket{monitored_resource="consumed_api",service=~"${mapsServiceRe}"}[1h])))'')
            ];
          })
        ];
        refresh = "";
        schemaVersion = 42;
        tags = [
          "gcp"
          "maps"
        ];
        templating.list = [ ];
        time = {
          from = "now-2d";
          to = "now";
        };
        timezone = "browser";
        title = "Google Maps Platform usage";
        uid = "maps-platform";
      };
      folder = "fleet";
      message = null;
      overwrite = null;
    };
  };
  grafana_data_source = {
    # Cloud Monitoring, read-only, through the grafana-monitoring-reader service account
    # (infra/gcp/foundation.nix). Its key exists only here, like fleet_history's.
    gcp_monitoring = {
      access_mode = "proxy";
      basic_auth_enabled = false;
      http_headers = null;
      is_default = false;
      json_data_encoded = builtins.toJSON {
        authenticationType = "jwt";
        clientEmail = "grafana-monitoring-reader@${gcpProjectId}.iam.gserviceaccount.com";
        defaultProject = gcpProjectId;
        tokenUri = "https://oauth2.googleapis.com/token";
        universeDomain = "googleapis.com";
      };
      name = "Google Cloud Monitoring";
      private_data_source_connect_network_id = null;
      secure_json_data_encoded = null;
      type = "stackdriver";
      uid = mapsDatasource;
    };
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
    maps_platform = {
      disable_provenance = true;
      folder_uid = "fleet";
      interval_seconds = 60;
      name = "maps-platform";
      # The datasource is referenced by a uid string, which gives no implicit ordering.
      depends_on = [ "grafana_data_source.gcp_monitoring" ];
      rule = [
        (mkRule {
          uid = "maps-geocode-quota";
          name = "Maps: geocoding near its daily quota";
          summary = "Geocoding used {{ humanizePercentage $values.B.Value }} of its daily quota in the last 24 h";
          description = "Rolling 24 h of geocoding-backend requests over the BillableDefaultPerDayPerProject limit (infra/gcp/foundation.nix). At 100% Google answers 429 until midnight Pacific; it cannot bill. Dashboard: maps-platform.";
          datasource = mapsDatasource;
          reduce = true;
          model = mapsQuery "sum(increase(serviceruntime_googleapis_com:api_request_count{${geocodeSel}}[1d])) / ${geocodeDailyLimit}";
          # The lookbacks live in the expression; the range only has to cover one step.
          rangeSeconds = 300;
          op = "gt";
          threshold = 0.8;
          for = "15m";
          labels = {
            domain = "gcp";
            severity = "warning";
          };
        })
        (mkRule {
          uid = "maps-error-ratio";
          name = "Maps: error ratio above 10%";
          summary = "{{ humanizePercentage $values.B.Value }} of Maps Platform calls in the last hour were not 2xx";
          description = "Non-2xx over all Maps Platform calls, 1 h window, only when there were at least 10 calls. 429 = quota cap hit, 403 = key restriction or API disabled. Dashboard: maps-platform.";
          datasource = mapsDatasource;
          reduce = true;
          model = mapsQuery "(sum(increase(${mapsReq '',response_code_class!="2xx"''}[1h])) / sum(increase(${mapsReq ""}[1h]))) and on() (sum(increase(${mapsReq ""}[1h])) >= 10)";
          rangeSeconds = 300;
          op = "gt";
          threshold = 0.1;
          for = "10m";
          labels = {
            domain = "gcp";
            severity = "warning";
          };
        })
      ];
    };
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
