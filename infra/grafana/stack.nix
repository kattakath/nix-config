# ---- Grafana Cloud stack `kattakath`: alerting, datasources, dashboard, probe ----------
#
# ADR-012 step 2 (docs/declarative-gaps-adr.md § 3 row 1). Everything ADR-011 built by hand in
# the Grafana Cloud stack, now declared. Rendered by modules/parts/terranix.nix
# (`grafana-plan` / `grafana-apply`), state encrypted in the shared GCS bucket like the others.
#
# ADOPTED, NOT CREATED: every object predates this stack, so each has an `import` block below.
# The first plan read "12 to import, 0 to add, 0 to change, 0 to destroy" (measured
# 2026-11-03); the three maps-platform objects, created 2026-11-07, joined after. An import block is a no-op once its object is in state, and the blocks ARE the
# empty-state guard: with state lost, each re-adopts its live object instead of creating (or,
# for a rule group, silently upserting over) it. So every resource needs one; the wrapper
# refuses an empty-state run where the counts differ.
#
# PROVIDER FROM NIXPKGS (ADR-012 § 3): the wrapper runs `opentofu.withPlugins` with
# `grafana_grafana` (4.50.0 in the pinned nixpkgs), so there is no registry download and no
# entry in provider-pins.nix. The version follows the flake's nixpkgs.
#
# CREDENTIALS are the provider's own env vars, filled by `secret exec` in the wrapper:
# GRAFANA_AUTH (service account `terranix`, Admin), GRAFANA_SM_ACCESS_TOKEN (the Synthetic
# Monitoring token) and GRAFANA_CLOUD_ACCESS_POLICY_TOKEN (the gcom token, for the access
# policy below). None reaches argv, the store or a rendered file.
#
# CREATED, NOT ADOPTED — the li-logs access policy and its token (ADR-011 § 4, the allowlisted
# run-metadata exception), made by the 2026-11-13 apply. The policy then got its import block
# like everything else (id from `li_logs_policy_id`). The token never gets one:
# the API returns its value only at create, so an imported token would be valueless, and the
# Keychain copy outlives lost state anyway. With state lost, GRAFANA_ALLOW_CREATE=1 re-mints it.
# The token is the one secret this stack holds in (encrypted) state, by the cf-tunnel
# precedent: a sensitive output that grafana-apply pipes straight into the Keychain.
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
  # The stack's region (config.fleet.grafanaRegion), shared with fleet-gauges.
  grafanaRegion,
  publicSiteUrl,
  ...
}:
let
  resources = import ./resources.nix { inherit operatorEmail gcpProjectId publicSiteUrl; };
  # The stack slug is the grafana.net subdomain; the stack id and its gcom region are read
  # from the stack itself rather than written here.
  stackSlug = lib.removeSuffix ".grafana.net" (lib.removePrefix "https://" grafanaUrl);
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
    "grafana_data_source.gcp_monitoring" = "gcp-monitoring";
    "grafana_dashboard.maps_platform" = "maps-platform";
    "grafana_rule_group.maps_platform" = "fleet:maps-platform";
    # Created here 2026-11-13, then adopted like the rest. `<region>:<policyId>`. Its token
    # has no block on purpose (header: an imported token has no value).
    "grafana_cloud_access_policy.li_logs" = "prod-ca-east-0:1919db4f-bf36-4d08-b018-65094d66096f";
  };
in
{
  terraform.required_providers.grafana.source = "grafana/grafana";

  provider.grafana = {
    url = grafanaUrl;
    sm_url = "https://synthetic-monitoring-api-${grafanaRegion}.grafana.net";
  };

  # The history Sheet's id is per-person data (the no-data rule), so it is not in the repo:
  # the wrapper reads the repository variable ROLLUP_SHEET_ID, the one copy the rollup uses.
  # Deliberately NOT `sensitive`, unlike the github stack's copy: it is a Drive id, not a
  # secret, and adding the flag now shows as a one-line in-place change on every plan until an
  # apply accepts it (operator decision, 2026-11-03).
  variable.rollup_sheet_id = {
    type = "string";
    description = "Drive id of the fleet-history Sheet (repo variable ROLLUP_SHEET_ID).";
  };

  import = lib.mapAttrsToList (to: id: { inherit to id; }) adopted;

  data.grafana_cloud_stack.this.slug = stackSlug;

  # The li-logs token is surfaced ONLY as a sensitive output; grafana-apply pipes it into
  # the Keychain item and never prints it (modules/parts/terranix.nix, mkGrafanaTofu).
  # Not a secret: the policy's import id is `<region>:<this>`.
  output.li_logs_policy_id.value = "\${grafana_cloud_access_policy.li_logs.policy_id}";
  output.li_logs_token = {
    value = "\${grafana_cloud_access_policy_token.li_logs.token}";
    sensitive = true;
  };

  # `org_id` is deliberately absent from resources.nix: in provider 4.50.0 it is ForceNew and
  # only suppresses a diff when unset, so a literal would turn a provider bump into a REPLACE
  # (terranix-infra-reviewer, 2026-11-03). The root policy also gets prevent_destroy: a destroy
  # or replace of it resets the whole routing tree.
  resource = resources // {
    # logs:write on THIS stack only: no read, no metrics, no other stack. Revoking it (or
    # deleting the policy) stops the li run-metadata logs and nothing else.
    grafana_cloud_access_policy.li_logs = {
      region = "\${data.grafana_cloud_stack.this.region_slug}";
      name = "li-logs-write";
      display_name = "li run metadata: logs write";
      scopes = [ "logs:write" ];
      realm = [
        {
          type = "stack";
          identifier = "\${data.grafana_cloud_stack.this.id}";
        }
      ];
    };
    grafana_cloud_access_policy_token.li_logs = {
      region = "\${data.grafana_cloud_stack.this.region_slug}";
      access_policy_id = "\${grafana_cloud_access_policy.li_logs.policy_id}";
      name = "li-logs";
      display_name = "li run metadata (claude-otel collector, macos)";
    };
    grafana_data_source = lib.mapAttrs (_: ignoreSecret) resources.grafana_data_source;
    grafana_notification_policy.root = resources.grafana_notification_policy.root // {
      lifecycle.prevent_destroy = true;
    };
  };
}
