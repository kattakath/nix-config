# Chrome browser policy for the organizational unit that holds enrolled browsers
# (terranix -> OpenTofu). ADR-005 § 3.3's narrow reopening: Chrome policy on ONE unit,
# nothing else in Google Workspace. The Mac side of the same feature is
# modules/darwin/chrome-enterprise.nix (the enrollment token).
#
# THIS FILE IS THE EXTENSION LIST. `extensions` below is the one source of truth for
# what Chrome force-installs on every profile of an enrolled browser. It replaced the
# Home Manager External Extensions lane (2026-11-15), which needed a manual enable per
# profile.
#
# ADOPTED, NOT CREATED. Every row was first set in the Admin console, so each resource
# carries an `import` block and the first plan must be EMPTY. Measured 2026-11-15 on a
# throwaway child unit, provider 1.5.3: create, re-plan (no changes), import (no
# changes) and an out-of-band change (shown as drift) all behaved.
#
# THREE TRAPS, all measured the same day, not read from docs:
#   1. ONE RESOURCE PER EXTENSION. The provider's Read collapses a multi-key resource
#      to its last key, so a shared resource hides drift on every other id. Hence the
#      per-id attrset below.
#   2. REMOVING AN ID DOES NOT UNINSTALL IT. Dropping a row makes tofu call
#      batchInherit, and the API refuses to inherit an install type no PARENT unit
#      sets ("Install Type can only be inherited if it is configured in a parent
#      Organizational Unit"). The provider swallows that 400 and reports the destroy
#      as done, so state says gone while the unit still forces the extension. To
#      remove one: delete its row in the Admin console (Chrome browser > Apps &
#      extensions), THEN drop it here. The engine's drop guard stops the silent half.
#   3. AN ID IS NEVER EDITED IN PLACE. A changed id is a remove (trap 2) plus an add.
#
# THE CREDENTIAL IS MINTED INSIDE THE PLAN. The `google` provider reads the operator's
# Application Default Credentials and asks IAM for a short-lived token for the
# Chrome-policy service account (infra/gcp/foundation.nix `ws_domain_admin`); the
# `googleworkspace` provider is handed that token. No key file, no domain-wide
# delegation, no gcloud call in a wrapper. The service account holds a Chrome-only
# admin role restricted to the one unit: measured, it reads the unit (200) and is
# refused on the root unit (403).
#
# BROWSER SETTINGS (2026-11-18) are the second, smaller list: `settings` below. Unlike
# the extensions they were never set in the console, so they are CREATED, with no
# `import` block. Each one names EVERY field of its schema (read from the API's
# policySchemas list): the provider reads the whole object back, so a field left out
# would show as drift. A two-valued setting is an enum STRING here ("TRUE"/"FALSE"),
# not a JSON boolean; that is how the API returns the ones the root unit sets.
# The root unit sets more policies in the console; the role cannot reach them.
#
# VARIABLE VALUES are per-tenant DATA and never committed: the engine reads the
# customer id and the unit id from repository Actions variables at run time
# (modules/parts/terranix.nix `mkGwsChromeTofu`), the infra/github/stack.nix precedent.
{
  lib,
  chromePolicyServiceAccount,
  ...
}:
let
  pins = import ../provider-pins.nix;
  scope = "https://www.googleapis.com/auth/chrome.management.policy";
  installTypeSchema = "chrome.users.apps.InstallType";

  # Chrome Web Store ids. The comment is the listing's name, for the reader only.
  extensions = [
    "ddkjiahejlhfcafbddmgiahcphecmpfh" # uBlock Origin Lite
    "caclkomlalccbpcdllchkeecicepbmbm" # Advanced Font Settings (Malayalam faces, hosts/macos.nix fonts.packages)
    "jinjaccalgkegednnccohejagnlnfdag" # Violentmonkey (its "Allow User Scripts" toggle has no policy: one manual click)
    "faeadnfmdfamenfhaipofoffijhlnkif" # Into The Black Hole — True Amoled Black theme
    "fbmkmdnlhacefjljljlbhkodfmfkijdh" # MeTube Downloader
    "pejdijmoenmkgeppbflobdenhhabjlaj" # iCloud Passwords
    "fcoeoabgfenejglbffodgkkbkcdhcgfn" # Claude in Chrome — the agents' only browser rail
  ];

  # Schema name (without the `chrome.users.` prefix) -> every field of that schema.
  settings = {
    # The default blocks DevTools on force-installed extensions, which is every
    # extension above. The second field's UNSET means "follow the first".
    DeveloperTools = {
      developerToolsAvailability = "DEVELOPER_TOOLS_AVAILABILITY_ENUM_ALWAYS_ALLOW_DEVELOPER_TOOLS";
      extensionDeveloperModeSettings = "EXTENSION_DEVELOPER_MODE_SETTINGS_ENUM_UNSET";
    };
    # No usage or crash reports to Google, and the toggle is locked.
    MetricsReportingEnabled = {
      metricsReportingEnabled = "FALSE";
      metricsReportingEnabledCategoryItemPolicyMode = "POLICY_MODE_MANDATORY";
    };
    # Visited URLs are not sent to Google.
    UrlKeyedAnonymizedDataCollectionEnabled = {
      urlKeyedAnonymizedDataCollectionEnabled = "FALSE";
    };
  };

  settingFor = schema: values: {
    org_unit_id = "\${var.org_unit_id}";
    policies = [
      {
        schema_name = "chrome.users.${schema}";
        schema_values = lib.mapAttrs (_: builtins.toJSON) values;
      }
    ];
  };

  idOk = id: builtins.match "[a-p]{32}" id != null;
  addr = id: "ext_${id}";

  policyFor =
    id:
    assert lib.assertMsg (idOk id)
      "infra/google-workspace/chrome.nix: '${id}' is not a Chrome extension id";
    {
      org_unit_id = "\${var.org_unit_id}";
      additional_target_keys = [
        {
          target_key = "app_id";
          target_value = "chrome:${id}";
        }
      ];
      policies = [
        {
          schema_name = installTypeSchema;
          schema_values.appInstallType = builtins.toJSON "FORCED";
        }
      ];
    };

  dataVar = description: {
    type = "string";
    inherit description;
  };
in
{
  terraform.required_providers = {
    googleworkspace = {
      source = "macadmins/googleworkspace";
      version = "= ${pins.googleworkspace}";
    };
    google = {
      source = "hashicorp/google";
      version = "= ${pins.google}";
    };
  };

  variable = {
    customer_id = dataVar "Google Workspace customer id (repo variable GWS_CUSTOMER_ID).";
    org_unit_id = dataVar "Id of the unit holding enrolled browsers, no `id:` prefix (repo variable GWS_CHROME_ORG_UNIT_ID).";
  };

  provider.google = { };

  data.google_service_account_access_token.chrome_policy = {
    target_service_account = chromePolicyServiceAccount;
    scopes = [ scope ];
    lifetime = "900s";
  };

  provider.googleworkspace = {
    customer_id = "\${var.customer_id}";
    access_token = "\${data.google_service_account_access_token.chrome_policy.access_token}";
    # The provider asks for twelve scopes by default; this list REPLACES them.
    oauth_scopes = [ scope ];
  };

  import = map (id: {
    to = "googleworkspace_chrome_policy.${addr id}";
    id = "id:\${var.org_unit_id}/app_id=chrome:${id}/${installTypeSchema}";
  }) extensions;

  resource.googleworkspace_chrome_policy =
    lib.listToAttrs (map (id: lib.nameValuePair (addr id) (policyFor id)) extensions)
    // lib.mapAttrs' (
      schema: values: lib.nameValuePair "set_${schema}" (settingFor schema values)
    ) settings;
}
