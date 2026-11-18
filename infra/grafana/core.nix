# What every domain leans on: the contact point, the notification policy, the Fleet
# folder and the three datasources.
{
  h,
  operatorEmail,
  gcpProjectId,
}:
let
  inherit (h)
    mapsDatasource
    ;
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
}
