# The Workspace add-on's part of the stack. It owns no whole resource: its two panels sit
# on the Fleet overview board and its rule in the fleet-health group, so it exports list
# FRAGMENTS and fleet.nix appends them, in that order, where they always were.
{
  h,
  addonGcpProjectId,
}:
let
  inherit (h)
    mapsDatasource
    mapsSeries
    mapsTarget
    mapsPanel
    mkRule
    ;
  # ---- The Workspace add-on, read from ITS project's Cloud Monitoring ----
  # Same datasource and builder as Maps, a different project. Two built-in metrics, so
  # nothing is installed in the add-on and no log line leaves Google: the count of its
  # log entries by severity, and its calls to the Docs and Drive APIs.
  inAddonProject =
    q:
    q
    // {
      timeSeriesList = q.timeSeriesList // {
        projectName = addonGcpProjectId;
      };
    };
  addonLogCount =
    {
      period,
      extra ? [ ],
      groupBys ? [ ],
    }:
    inAddonProject (mapsSeries {
      filters = [
        "metric.type"
        "="
        "logging.googleapis.com/log_entry_count"
        # The script's own entries only: without the type, each resource type in the
        # project is its own series (3 measured), so a rule on it would split.
        "AND"
        "resource.type"
        "="
        "app_script_function"
      ]
      ++ extra;
      inherit period groupBys;
    });
  addonErrors =
    period:
    addonLogCount {
      inherit period;
      extra = [
        "AND"
        "metric.label.severity"
        "="
        "ERROR"
      ];
    };
  addonApiCalls =
    period:
    inAddonProject (mapsSeries {
      filters = [
        "metric.type"
        "="
        "serviceruntime.googleapis.com/api/request_count"
        "AND"
        "resource.type"
        "="
        "consumed_api"
        "AND"
        "resource.label.service"
        "=~"
        "(docs|drive)\\.googleapis\\.com"
      ];
      inherit period;
      groupBys = [ "resource.label.service" ];
    });
  addonPanel =
    {
      title,
      description,
      query,
      x,
    }:
    mapsPanel {
      inherit title description;
      type = "timeseries";
      gridPos = {
        h = 8;
        w = 12;
        inherit x;
        y = 28;
      };
      targets = [ (mapsTarget "A" query) ];
    };
in
{
  panels = [
    (addonPanel {
      title = "JSON Resume Connect: log entries per hour by severity";
      description = "Counts only, from the add-on's own project. An ERROR here is what the alert watches.";
      query = addonLogCount {
        period = 3600;
        groupBys = [ "metric.label.severity" ];
      };
      x = 0;
    })
    (addonPanel {
      title = "JSON Resume Connect: Docs and Drive calls per hour";
      description = "The add-on's calls to the two Google APIs it uses: a proxy for use, since Google exposes no install or execution count to a service account.";
      query = addonApiCalls 3600;
      x = 12;
    })
  ];
  rules = [
    (mkRule {
      uid = "fleet-addon-errors";
      name = "JSON Resume Connect logged an error";
      summary = "The add-on logged {{ $values.B }} error(s) in the last hour";
      description = "ERROR entries in the add-on project's Cloud Logging, counted by logging.googleapis.com/log_entry_count. Read them in that project's Logs Explorer (severity=ERROR). No error means no series, which evaluates to OK.";
      datasource = mapsDatasource;
      model = addonErrors 3600;
      rangeSeconds = 3600;
      reduce = true;
      op = "gt";
      threshold = 0;
      # Not 0s: a query error also alerts (exec_err_state), and one transient Cloud
      # Monitoring error should not email. An error stays in the hour bucket long enough.
      for = "10m";
      labels = {
        domain = "product";
        severity = "warning";
      };
    })
  ];
}
