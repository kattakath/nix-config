# The self-hosted MCP servers on Cloud Run (infra/gcp/self-hosted-mcp.nix): one dashboard
# and one rule group, read live from Cloud Monitoring by the `gcp-monitoring` datasource.
# Cloud Run exports request_count, request_latencies and instance_count automatically and
# at no charge (docs.cloud.google.com/run/docs/monitoring), so nothing is stored in
# Grafana and nothing is added to the services. Built on helpers.nix's Cloud Monitoring
# builders, the same ones maps.nix uses.
{
  h,
  gcpProjectId,
  gcpProjectNumber,
}:
let
  inherit (h)
    mapsDatasource
    mapsSeries
    reduceLast
    math
    mapsTarget
    mapsPanel
    ruleNode
    mkRule
    smProbeIds
    ;

  # The service names come from the portal's app list, the one place they are declared;
  # the project number makes each one's run.app URL (Cloud Run's deterministic form).
  selfHosted = map (a: a.selfHosted) (
    builtins.filter (a: a ? selfHosted) (
      builtins.attrValues (import ../cloudflare/workspace-mcp-apps.nix).apps
    )
  );
  services = map (x: x.service) selfHosted;
  serviceRe = builtins.concatStringsSep "|" services;

  runFilter =
    metric: extra:
    [
      "metric.type"
      "="
      "run.googleapis.com/${metric}"
      "AND"
      "resource.type"
      "="
      "cloud_run_revision"
      "AND"
      "resource.label.service_name"
      "=~"
      serviceRe
    ]
    ++ extra;
  byService = [ "resource.label.service_name" ];
  hour = 3600;

  requests =
    {
      period,
      extra ? [ ],
      groupBys ? [ ],
    }:
    mapsSeries {
      filters = runFilter "request_count" extra;
      inherit period groupBys;
    };
  errors5xx = [
    "AND"
    "metric.label.response_code_class"
    "="
    "5xx"
  ];

  series =
    {
      title,
      description,
      x,
      y,
      unit ? "short",
      target,
    }:
    mapsPanel {
      inherit title description unit;
      type = "timeseries";
      gridPos = {
        h = 8;
        w = 12;
        inherit x y;
      };
      targets = [ (mapsTarget "A" target) ];
    };
in
{
  grafana_dashboard.self_hosted_mcp = {
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
            content = "The portal's self-hosted MCP servers (${builtins.concatStringsSep ", " services}) on Cloud Run in **${gcpProjectId}**, read live from Cloud Monitoring. Each scales to zero, so gaps are normal and the first call after one pays a cold start. 401s are expected (a call without a Google token); 5xx are not.";
            mode = "markdown";
          };
          title = "About";
          type = "text";
        }
        (series {
          title = "Requests by service";
          description = "run.googleapis.com/request_count, per 5 minutes.";
          x = 0;
          y = 3;
          target = requests {
            period = 300;
            groupBys = byService;
          };
        })
        (series {
          title = "5xx by service";
          description = "Server errors only. A 401 is a call without a valid Google token and is not counted here.";
          x = 12;
          y = 3;
          target = requests {
            period = 300;
            extra = errors5xx;
            groupBys = byService;
          };
        })
        (series {
          title = "p95 latency by service";
          description = "run.googleapis.com/request_latencies, 95th percentile per 5 minutes. Cold starts show as spikes.";
          x = 0;
          y = 11;
          unit = "ms";
          target = mapsSeries {
            filters = runFilter "request_latencies" [ ];
            period = 300;
            aligner = "ALIGN_PERCENTILE_95";
            reducer = "REDUCE_MAX";
            groupBys = byService;
          };
        })
        (series {
          title = "Instances by service";
          description = "run.googleapis.com/container/instance_count (max 1 each; 0 = scaled to zero).";
          x = 12;
          y = 11;
          target = mapsSeries {
            filters = runFilter "container/instance_count" [ ];
            period = 300;
            aligner = "ALIGN_MAX";
            reducer = "REDUCE_SUM";
            groupBys = byService;
          };
        })
      ];
      schemaVersion = 42;
      tags = [
        "gcp"
        "mcp"
      ];
      time = {
        from = "now-2d";
        to = "now";
      };
      timezone = "browser";
      title = "Self-hosted MCP servers";
      uid = "self-hosted-mcp";
    };
    folder = "fleet";
    message = null;
    overwrite = null;
  };

  # ---- Reachability: Grafana Synthetic Monitoring, the same lane as nixpi's public site --
  # GET /health (the server's own route, 200 when up) from the stack's probes, HOURLY: a
  # scaled-to-zero service is woken at most once an hour, and 4 checks x 3 probes x 720
  # runs stay far inside Synthetic Monitoring's free executions.
  grafana_synthetic_monitoring_check = builtins.listToAttrs (
    map (x: {
      name = "self_hosted_mcp_${builtins.replaceStrings [ "-" ] [ "_" ] x.service}";
      value = {
        alert_sensitivity = "";
        basic_metrics_only = true;
        enabled = true;
        frequency = 3600000;
        job = "self-hosted-mcp-${x.service}";
        labels = {
          domain = "gcp";
          inherit (x) service;
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
                valid_status_codes = [ 200 ];
              }
            ];
          }
        ];
        target = "https://${x.service}-${gcpProjectNumber}.${x.region}.run.app/health";
        # A cold start (scale from zero) takes seconds; leave room for it.
        timeout = 20000;
      };
    }) selfHosted
  );

  grafana_rule_group.self_hosted_mcp = {
    disable_provenance = true;
    folder_uid = "fleet";
    interval_seconds = 60;
    name = "self-hosted-mcp";
    # The datasource is referenced by a uid string, which gives no implicit ordering.
    depends_on = [ "grafana_data_source.gcp_monitoring" ];
    rule = [
      (mkRule {
        uid = "self-hosted-mcp-5xx";
        name = "Self-hosted MCP: 5xx ratio above 10%";
        summary = "{{ humanizePercentage $values.B.Value }} of self-hosted MCP calls in the last hour were 5xx";
        description = "5xx over all calls to the portal's self-hosted MCP servers (${serviceRe}), 1 h window, only when there were at least 5 calls. Check the service's logs in Cloud Logging, then its last revision. Dashboard: self-hosted-mcp.";
        datasource = mapsDatasource;
        # A = 5xx calls, T = all calls, one hourly bucket each. No 5xx means A is absent
        # and B is no data, which evaluates to OK.
        model = requests {
          period = hour;
          extra = errors5xx;
        };
        rangeSeconds = hour;
        extraData = [
          (ruleNode {
            refId = "T";
            model = requests { period = hour; };
            datasource = mapsDatasource;
            rangeSeconds = hour;
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
            model = math "$RA / $RT * ($RT >= 5)";
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
      # Denial-of-wallet early warning. Each server accepts ANY valid Google token (no
      # audience or email check upstream in external-OAuth mode), so a stranger can spend
      # this project's Cloud Run time with their own token. One operator's routines and
      # chats make tens of calls an hour; 300 is far above that and far below where the
      # free tier's 2M requests a month would run out (~2,700/h sustained).
      (mkRule {
        uid = "self-hosted-mcp-spike";
        name = "Self-hosted MCP: request spike";
        summary = "{{ $values.B.Value }} self-hosted MCP requests in the last hour";
        description = "All calls to the portal's self-hosted MCP servers (${serviceRe}) over 1 h exceeded 300. They accept any valid Google token, so a spike can be a stranger spending this project's Cloud Run time. Check request counts per service on the dashboard and the callers in Cloud Logging. Dashboard: self-hosted-mcp.";
        datasource = mapsDatasource;
        model = requests { period = hour; };
        rangeSeconds = hour;
        extraData = [
          (ruleNode {
            refId = "B";
            model = reduceLast "A";
          })
        ];
        thresholdOn = "B";
        op = "gt";
        threshold = 300;
        for = "0s";
        labels = {
          domain = "gcp";
          severity = "warning";
        };
      })
      (mkRule {
        uid = "self-hosted-mcp-down";
        name = "Self-hosted MCP: /health failing";
        summary = "A self-hosted MCP server failed its /health check from most probes";
        description = "Synthetic Monitoring's hourly GET /health (jobs self-hosted-mcp-*) succeeded from under half the probes over the last 3 h. Check the Cloud Run service's latest revision and logs. Dashboard: self-hosted-mcp.";
        expr = "min(avg_over_time(probe_success{job=~\"self-hosted-mcp-.*\"}[3h]))";
        rangeSeconds = 3 * hour;
        op = "lt";
        threshold = 0.5;
        for = "0s";
        labels = {
          domain = "gcp";
          severity = "warning";
        };
      })
    ];
  };
}
