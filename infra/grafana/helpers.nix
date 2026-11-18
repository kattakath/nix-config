# The shared builders of the Grafana stack's resources: alert rules (`mkRule`, `ruleNode`),
# the Cloud Monitoring query and panel builders, the Fleet overview panel builders, and the
# values several domains read (nixpi units, the redaction canary). One copy, handed to
# each domain file by resources.nix as `h`; a domain file never imports another.
{
  gcpProjectId,
  publicSiteUrl,
}:
rec {
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
  # Monitoring with the timeSeriesList builder (the projects.timeSeries.list filter API), so
  # none of this costs a Grafana series. Not PromQL: plugin 12.6.4 panics (nil pointer
  # dereference) on EVERY PromQL query, even `up`, while timeSeriesList over the same data
  # answers (measured 2026-11-08). Every Maps Platform API reports
  # `serviceruntime.googleapis.com/api/request_count` on the `consumed_api` resource; the
  # `*-backend` services are the legacy Maps web services (geocoding-, places-, directions-,
  # distance-matrix-, elevation-, timezone-, maps-, static-maps-backend), the rest are the
  # newer Maps APIs. Windows are FIXED alignment periods: Cloud Monitoring aligns buckets to
  # the END of the range, so one period over an equal range is a rolling window ending now.
  mapsDatasource = "gcp-monitoring";
  # One backslash reaches the filter's monitoring.regex.full_match (RE2).
  mapsServiceRe = builtins.concatStringsSep "|" [
    ".*-backend\\.googleapis\\.com"
    "places\\.googleapis\\.com"
    "routes\\.googleapis\\.com"
    "addressvalidation\\.googleapis\\.com"
    "geolocation\\.googleapis\\.com"
    "roads\\.googleapis\\.com"
  ];
  day = 86400;
  geocodeService = "geocoding-backend.googleapis.com";
  # The plugin's filter list: [ key op value "AND" key op value ... ].
  requestFilter =
    metric: service: extra:
    [
      "metric.type"
      "="
      "serviceruntime.googleapis.com/api/${metric}"
      "AND"
      "resource.type"
      "="
      "consumed_api"
      "AND"
      "resource.label.service"
    ]
    ++ (
      if service == null then
        [
          "=~"
          mapsServiceRe
        ]
      else
        [
          "="
          service
        ]
    )
    ++ extra;
  non2xx = [
    "AND"
    "metric.label.response_code_class"
    "!="
    "2xx"
  ];
  mapsSeries =
    {
      filters,
      period,
      aligner ? "ALIGN_DELTA",
      reducer ? "REDUCE_SUM",
      groupBys ? [ ],
    }:
    {
      queryType = "timeSeriesList";
      timeSeriesList = {
        projectName = gcpProjectId;
        inherit filters groupBys;
        crossSeriesReducer = reducer;
        perSeriesAligner = aligner;
        alignmentPeriod = "+${toString period}s";
      };
    };
  # Request counts per alignment period, over every Maps API (service = null) or one.
  requests =
    {
      period,
      service ? null,
      groupBys ? [ ],
      extra ? [ ],
      aligner ? "ALIGN_DELTA",
    }:
    mapsSeries {
      filters = requestFilter "request_count" service extra;
      inherit period groupBys aligner;
    };
  # quota/limit is written sparsely (measured 2026-11-07), so ALIGN_NEXT_OLDER over a week
  # always finds the latest value.
  geocodeQuota = mapsSeries {
    filters = [
      "metric.type"
      "="
      "serviceruntime.googleapis.com/quota/limit"
      "AND"
      "resource.type"
      "="
      "consumer_quota"
      "AND"
      "resource.label.service"
      "="
      geocodeService
      "AND"
      "metric.label.limit_name"
      "="
      "BillableDefaultPerDayPerProject"
    ];
    period = 7 * day;
    aligner = "ALIGN_NEXT_OLDER";
    reducer = "REDUCE_MAX";
  };
  # Geocoding is an Essentials SKU: 10,000 free calls a month, then 5 USD per 1,000
  # (https://developers.google.com/maps/billing-and-pricing/pricing, since 2025-03-01).
  # The 300/day quota in infra/gcp/foundation.nix keeps a 31-day month at 9,300.
  geocodeFreePerMonth = 10000;
  geocodeUsdPerCall = 0.005;
  # abs() only turns the -0 of `0 * negative` into 0; the product is never below zero.
  geocodeCostExpr =
    ref:
    "abs((${ref} > ${toString geocodeFreePerMonth}) * (${ref} - ${toString geocodeFreePerMonth}) * ${toString geocodeUsdPerCall})";
  # Grafana server-side expressions, shared by the panels and the rules. Reducing an ABSENT
  # series yields nothing, so an expression over it is no data (the rules map that to OK).
  reduceLast = expression: {
    inherit expression;
    reducer = "last";
    settings.mode = "dropNN";
    type = "reduce";
  };
  math = expression: {
    inherit expression;
    type = "math";
  };
  mapsTarget =
    refId: query:
    query
    // {
      datasource = {
        type = "stackdriver";
        uid = mapsDatasource;
      };
      inherit refId;
    };
  exprTarget =
    refId: model:
    model
    // {
      datasource = {
        type = "__expr__";
        uid = "__expr__";
      };
      inherit refId;
    };
  # An intermediate query or expression: computed, not drawn.
  hidden = t: t // { hide = true; };

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
      # A fixed window for a rolling-total panel, independent of the dashboard's range.
      timeFrom ? null,
      hideTimeOverride ? false,
    }:
    (if timeFrom == null then { } else { inherit timeFrom hideTimeOverride; })
    // {
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

  # One extra rule data node for mkRule's extraData: a datasource query (pass its uid and
  # its lookback in seconds) or, by default, a server-side expression.
  ruleNode =
    {
      refId,
      model,
      datasource ? "__expr__",
      rangeSeconds ? 0,
    }:
    {
      datasource_uid = datasource;
      model = builtins.toJSON (model // { inherit refId; });
      ref_id = refId;
      relative_time_range = [
        {
          from = rangeSeconds;
          to = 0;
        }
      ];
    }
    // (if model ? queryType then { query_type = model.queryType; } else { });

  # ---- Fleet overview dashboard: one screen over series that already arrive ----
  # Hand-written because its top row is this fleet's own gauges (packages/fleet-gauges.py),
  # which no catalogue board knows. The grafana.com catalogue does carry boards for otelcol
  # hostmetrics and for Claude Code; this one takes two panels from each subject, not a copy.
  fleetProm = {
    type = "prometheus";
    uid = "grafanacloud-prom";
  };
  # The Mac's Data volume: APFS volumes share one container, so its free space is the
  # container's. Same 10% line as fleet-doctor's FD-E-disk-free.
  macDiskFreePct =
    let
      sel =
        state:
        ''system_filesystem_usage_bytes{service_name="macos-host",mountpoint="/System/Volumes/Data",state${state}}'';
    in
    "100 * sum(last_over_time(${sel ''="free"''}[1h])) / sum(last_over_time(${sel ''=~"free|used"''}[1h]))";
  # A count that should be 0: green at 0, red from 1.
  fleetStat =
    {
      title,
      expr,
      x,
      y,
      description ? null,
    }:
    {
      datasource = fleetProm;
      inherit title;
      fieldConfig = {
        defaults = {
          color.mode = "thresholds";
          thresholds = {
            mode = "absolute";
            steps = [
              {
                color = "green";
                value = null;
              }
              {
                color = "red";
                value = 1;
              }
            ];
          };
        };
        overrides = [ ];
      };
      gridPos = {
        h = 4;
        w = 4;
        inherit x y;
      };
      options = {
        colorMode = "background";
        graphMode = "none";
        reduceOptions = {
          calcs = [ "lastNotNull" ];
          fields = "";
          values = false;
        };
      };
      targets = [
        {
          datasource = fleetProm;
          inherit expr;
          instant = true;
          refId = "A";
        }
      ];
      type = "stat";
    }
    // (if description == null then { } else { inherit description; });
  fleetSeries =
    {
      title,
      expr,
      legend,
      x,
      y,
      unit ? "short",
      description ? null,
    }:
    {
      datasource = fleetProm;
      inherit title;
      fieldConfig = {
        defaults = { inherit unit; };
        overrides = [ ];
      };
      gridPos = {
        h = 8;
        w = 12;
        inherit x y;
      };
      options.legend = {
        displayMode = "list";
        placement = "bottom";
      };
      targets = [
        {
          datasource = fleetProm;
          inherit expr;
          legendFormat = legend;
          refId = "A";
        }
      ];
      type = "timeseries";
    }
    // (if description == null then { } else { inherit description; });

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
      # Loki ignores `instant` and answers a range series, which alerting refuses ("only
      # reduced data can be alerted on"): its switch is queryType (measured 2026-11-18,
      # 1561 points against 1). That error kept one canary rule firing for two weeks.
      model ?
        if datasource == "grafanacloud-logs" then
          {
            inherit expr;
            queryType = "instant";
          }
        else
          {
            inherit expr;
            instant = true;
          },
      # Insert a reduce node B (last value) between A and the threshold. Needed by a
      # datasource whose backend only answers range queries: the stackdriver plugin calls
      # query_range alone, and Grafana refuses to alert on a series that is not reduced.
      reduce ? false,
      # More nodes after A (and B), built with ruleNode: a second query, its reduce, the
      # math that combines them. thresholdOn names the node C tests.
      extraData ? [ ],
      thresholdOn ? if reduce then "B" else "A",
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
          # Grafana copies the model's queryType onto the query; undeclared, every plan
          # shows `query_type = "promQL" -> null` (measured 2026-11-07). null = unset.
          query_type = model.queryType or null;
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
      ++ extraData
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
            expression = thresholdOn;
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
}
