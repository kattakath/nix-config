# ---- Grafana Cloud stack `kattakath`: alerting, datasources, dashboard, probe ----------
#
# ADR-012 step 2 (docs/declarative-gaps-adr.md § 3 row 1). Everything ADR-011 built by hand in
# the Grafana Cloud stack, now declared. Rendered by modules/parts/terranix.nix
# (`grafana-plan` / `grafana-apply`), state encrypted in the shared GCS bucket like the others.
#
# ADOPTED, NOT CREATED: every object predates this stack, so each has an `import` block below.
# The first plan reads "12 to import, 0 to add, 0 to change, 0 to destroy" (measured
# 2026-11-03). An import block is a no-op once its object is in state, and the blocks ARE the
# empty-state guard: with state lost, each re-adopts its live object instead of creating (or,
# for a rule group, silently upserting over) it. So every resource needs one; the wrapper
# refuses an empty-state run where the counts differ.
#
# PROVIDER FROM NIXPKGS (ADR-012 § 3): the wrapper runs `opentofu.withPlugins` with
# `grafana_grafana` (4.50.0 in the pinned nixpkgs), so there is no registry download and no
# entry in provider-pins.nix. The version follows the flake's nixpkgs.
#
# CREDENTIALS are the provider's own env vars, filled by `secret exec` in the wrapper:
# GRAFANA_AUTH (service account `terranix`, Admin) and GRAFANA_SM_ACCESS_TOKEN (the Synthetic
# Monitoring token). Neither reaches argv, the store or a rendered file.
#
# DATASOURCE SECRETS ARE NEVER TERRAFORM'S. Grafana never returns `secure_json_data`, and the
# two keys it holds (the GitHub App PEM, the Sheets reader's service-account key) exist ONLY in
# Grafana by design (ADR-011 step 6 and step 11). So the field is ignored: the stack declares
# everything about each datasource except its secret, and never puts a secret in state.
{
  lib,
  operatorEmail,
  gcpProjectId,
  grafanaUrl,
  publicSiteUrl,
  ...
}:
let
  resources = import ./resources.nix { inherit operatorEmail gcpProjectId publicSiteUrl; };
  # prevent_destroy too: ignore_changes keeps the secret out of the diff, but would not stop a
  # destroy or replace, and a replaced datasource loses a key that exists nowhere else.
  ignoreSecret =
    ds:
    ds
    // {
      lifecycle = {
        ignore_changes = [ "secure_json_data_encoded" ];
        prevent_destroy = true;
      };
    };

  # address = live id. The four rule groups are `<folder uid>:<group name>`.
  adopted = {
    "grafana_folder.fleet" = "fleet";
    "grafana_folder.agentic_jobseek" = "agentic-jobseek";
    "grafana_dashboard.evidence_pipeline" = "evidence-pipeline";
    "grafana_data_source.fleet_history" = "fleet-history";
    "grafana_data_source.github" = "github";
    "grafana_contact_point.operator_email" = "operator-email";
    "grafana_notification_policy.root" = "policy";
    "grafana_rule_group.free_tier" = "fleet:free-tier";
    "grafana_rule_group.nixpi" = "fleet:nixpi";
    "grafana_rule_group.fleet_health" = "fleet:fleet-health";
    "grafana_rule_group.career" = "fleet:career";
    "grafana_synthetic_monitoring_check.public_site" = "15886";
  };
in
{
  terraform.required_providers.grafana.source = "grafana/grafana";

  provider.grafana = {
    url = grafanaUrl;
    sm_url = "https://synthetic-monitoring-api-ca-east-0.grafana.net";
  };

  # The history Sheet's id is per-person data (the no-data rule), so it is not in the repo:
  # the wrapper reads the repository variable ROLLUP_SHEET_ID, the one copy the rollup uses.
  variable.rollup_sheet_id = {
    type = "string";
    description = "Drive id of the fleet-history Sheet (repo variable ROLLUP_SHEET_ID).";
  };

  import = lib.mapAttrsToList (to: id: { inherit to id; }) adopted;

  # `org_id` is deliberately absent from resources.nix: in provider 4.50.0 it is ForceNew and
  # only suppresses a diff when unset, so a literal would turn a provider bump into a REPLACE
  # (terranix-infra-reviewer, 2026-11-03). The root policy also gets prevent_destroy: a destroy
  # or replace of it resets the whole routing tree.
  resource = resources // {
    grafana_data_source = lib.mapAttrs (_: ignoreSecret) resources.grafana_data_source;
    grafana_notification_policy.root = resources.grafana_notification_policy.root // {
      lifecycle.prevent_destroy = true;
    };
  };
}
