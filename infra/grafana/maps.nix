# Google Maps Platform usage: its dashboard and rule group, read live from Cloud Monitoring.
{
  h,
  gcpProjectId,
}:
let
  inherit (h)
    mapsDatasource
    day
    geocodeService
    requestFilter
    non2xx
    mapsSeries
    requests
    geocodeQuota
    geocodeFreePerMonth
    geocodeUsdPerCall
    geocodeCostExpr
    reduceLast
    math
    mapsTarget
    exprTarget
    hidden
    mapsPanel
    ruleNode
    mkRule
    ;
in
{
  grafana_dashboard = {
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
            # A week, so the sparse quota series is found; A's last daily bucket is the
            # rolling 24 h. The override is hidden because the gauge shows 24 h, not 7 d.
            timeFrom = "7d";
            hideTimeOverride = true;
            targets = [
              (hidden (
                mapsTarget "A" (requests {
                  period = day;
                  service = geocodeService;
                })
              ))
              (hidden (mapsTarget "Q" geocodeQuota))
              (hidden (exprTarget "RA" (reduceLast "A")))
              (hidden (exprTarget "RQ" (reduceLast "Q")))
              (exprTarget "B" (math "$RA / $RQ"))
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
            timeFrom = "24h";
            targets = [
              (mapsTarget "A" (requests {
                period = day;
              }))
            ];
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
            timeFrom = "30d";
            targets = [
              (mapsTarget "A" (requests {
                period = 30 * day;
                service = geocodeService;
              }))
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
            timeFrom = "30d";
            targets = [
              (hidden (
                mapsTarget "A" (requests {
                  period = 30 * day;
                  service = geocodeService;
                })
              ))
              (hidden (exprTarget "RA" (reduceLast "A")))
              (exprTarget "B" (math (geocodeCostExpr "$RA")))
            ];
            options.reduceOptions.calcs = [ "lastNotNull" ];
          })
          (mapsPanel {
            title = "Requests per minute by API, method and response class";
            type = "timeseries";
            description = "ALIGN_RATE over 10 m, x 60.";
            gridPos = {
              h = 9;
              w = 24;
              x = 0;
              y = 9;
            };
            unit = "reqpm";
            targets = [
              (hidden (
                mapsTarget "A" (requests {
                  period = 600;
                  aligner = "ALIGN_RATE";
                  groupBys = [
                    "resource.label.service"
                    "resource.label.method"
                    "metric.label.response_code_class"
                  ];
                })
              ))
              (exprTarget "B" (math "$A * 60"))
            ];
          })
          (mapsPanel {
            title = "Error ratio (non-2xx) by API";
            type = "timeseries";
            description = "Share of calls that did not return 2xx, per 1 h bucket. A 429 here usually means the daily quota cap was hit. No data means no non-2xx call in the range.";
            gridPos = {
              h = 8;
              w = 12;
              x = 0;
              y = 18;
            };
            unit = "percentunit";
            targets = [
              (hidden (
                mapsTarget "E" (requests {
                  period = 3600;
                  groupBys = [ "resource.label.service" ];
                  extra = non2xx;
                })
              ))
              (hidden (
                mapsTarget "T" (requests {
                  period = 3600;
                  groupBys = [ "resource.label.service" ];
                })
              ))
              (exprTarget "A" (math "$E / $T"))
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
            # REDUCE_PERCENTILE over ALIGN_DELTA merges every series' distribution first, so
            # it is the percentile of all calls to the API. ALIGN_PERCENTILE_* would be a
            # percentile per series (per key, location, method), which cannot be combined.
            targets =
              map
                (
                  { refId, p }:
                  mapsTarget refId (mapsSeries {
                    filters = requestFilter "request_latencies" null [ ];
                    period = 3600;
                    reducer = "REDUCE_PERCENTILE_${p}";
                    groupBys = [ "resource.label.service" ];
                  })
                )
                [
                  {
                    refId = "A";
                    p = "50";
                  }
                  {
                    refId = "B";
                    p = "95";
                  }
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
          # A = requests in ONE daily bucket over a one-day range: the rolling 24 h.
          model = requests {
            period = day;
            service = geocodeService;
          };
          rangeSeconds = day;
          extraData = [
            (ruleNode {
              refId = "Q";
              model = geocodeQuota;
              datasource = mapsDatasource;
              rangeSeconds = 7 * day;
            })
            (ruleNode {
              refId = "RA";
              model = reduceLast "A";
            })
            (ruleNode {
              refId = "RQ";
              model = reduceLast "Q";
            })
            (ruleNode {
              refId = "B";
              model = math "$RA / $RQ";
            })
          ];
          thresholdOn = "B";
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
          # A = non-2xx calls, T = all calls, each one hourly bucket over a one-hour range.
          # No non-2xx call means A is absent and B is no data, which evaluates to OK.
          model = requests {
            period = 3600;
            extra = non2xx;
          };
          rangeSeconds = 3600;
          extraData = [
            (ruleNode {
              refId = "T";
              model = requests { period = 3600; };
              datasource = mapsDatasource;
              rangeSeconds = 3600;
            })
            (ruleNode {
              refId = "RA";
              model = reduceLast "A";
            })
            (ruleNode {
              refId = "RT";
              model = reduceLast "T";
            })
            (ruleNode {
              refId = "B";
              model = math "$RA / $RT * ($RT >= 10)";
            })
          ];
          thresholdOn = "B";
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
  };
}
