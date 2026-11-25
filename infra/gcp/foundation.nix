# ---- GCP foundation: APIs, automation identity, state bucket ---------------
#
# ADR-005 phases 1 and 3. Everything here was created BY HAND during the
# 2026-09-22 session and is codified retroactively, then imported — so the plan
# reads empty rather than proposing to recreate what already exists.
#
# > An import is correct when the plan is EMPTY.
#
# WHY THIS STACK'S STATE STAYS LOCAL
# ==================================
# It declares the bucket that holds every OTHER stack's state. A stack cannot
# store its state in a bucket it is itself creating — the first `init` would need
# the bucket to exist before the apply that creates it. So this one keeps local
# state, in its own pinned directory, and every other stack moves to GCS.
#
# That is not a gap left open: this stack changes roughly never (an API, an IAM
# binding, a bucket setting), and the per-user-state hazard that motivated a
# remote backend is about the stacks that change weekly.
#
# WHO RUNS IT
# ===========
# The OPERATOR, as themselves — not the automation service account this stack
# declares. See the note on `provider.google` below for why that is a privilege
# decision rather than convenience. It also removes a chicken-and-egg: a stack
# that impersonated the account it creates could never run on a fresh project.
{
  lib,
  projectId,
  addonProjectId,
  billingAccountId,
  operatorAccount,
  automationServiceAccount,
  stateBucket,
  stateBucketLocation,
  # ADR-011 step 11: `<org>/<repo>`, whose ONE workflow file on main may act as the rollup
  # writer (see attribute_condition). Any other workflow, fork, or PR branch gets a token
  # GitHub signed, and WIF refuses it on Google's side. From config.fleet's orgName/repoName,
  # so renaming either moves this trust condition at the next apply, as it should.
  rollupRepo,
  # The writer's account id; modules/parts/terranix.nix also builds its email from it.
  rollupWriterAccountId,
  # The Chrome-policy account's id; modules/parts/terranix.nix also builds its email from it.
  wsDomainAdminAccountId,
  ...
}:
let
  # The short name, as `google_service_account` wants it — the resource takes an
  # account_id, not the full email, while every IAM binding takes the email.
  saAccountId = lib.head (lib.splitString "@" automationServiceAccount);

  # Organization roles only the operator may hold (see "Who may create" below).
  # The attribute name is the resource's address in state: renaming one is a move.
  operatorOnlyOrgRoles = {
    billing_creator = "roles/billing.creator";
    project_creator = "roles/resourcemanager.projectCreator";
  };

  # Organization roles the operator holds and must never lose (see "Who may create").
  # Same rule as above: the attribute name is the address in state.
  operatorOrgGrants = {
    operator_organization_admin = "roles/resourcemanager.organizationAdmin";
    operator_org_policy_admin = "roles/orgpolicy.policyAdmin";
    operator_service_usage_viewer = "roles/serviceusage.serviceUsageViewer";
  };

  # APIs this fleet actually turned on, each with the reason it exists. Enabling
  # an API is free; the cost of NOT declaring one is a 403 whose text names a
  # permission rather than a missing service, which is how 2026-09-22 went.
  services = {
    "billingbudgets.googleapis.com" = "the spend alert (infra/gcp/budget.nix)";
    "iamcredentials.googleapis.com" = "service-account impersonation, how tofu authenticates";
    "secretmanager.googleapis.com" =
      "the keychain-secrets durable copy (ADR-004, docs/secrets-recovery-and-identity-adr.md §9.3)";
    "storage.googleapis.com" = "the OpenTofu state bucket below";
    "iam.googleapis.com" = "service accounts and the Workload Identity pool (ADR-011 step 11)";
    "sts.googleapis.com" =
      "Workload Identity Federation token exchange for the Grafana rollup (ADR-011 step 11)";
    "sheets.googleapis.com" =
      "the rollup writes, and Grafana reads, the history Sheet (ADR-011 step 11)";
    "searchconsole.googleapis.com" =
      "kattakath.com search analytics, URL inspection and sitemap submit, called with operator ADC";
    "pagespeedonline.googleapis.com" = "PageSpeed Insights / Core Web Vitals checks for kattakath.com";
    "geocoding-backend.googleapis.com" =
      "Geocoding API: address text to coordinates for operator scripts (key below)";
    "apikeys.googleapis.com" = "API Keys API, which manages the restricted geocoding key below";
    "cloudquotas.googleapis.com" =
      "Cloud Quotas API, which holds the geocoding daily request cap below";
    "gmail.googleapis.com" = "gmailctl's filter sync (packages/gmail-filters.nix), operator ADC";
    "admin.googleapis.com" = "Admin SDK, enabled 2026-09-07 with ws_domain_admin below";
    "chromepolicy.googleapis.com" =
      "Chrome Policy API: Chrome browser policy on one organizational unit, as ws_domain_admin (ADR-005 § 3.3)";
    # Operator-enabled by hand (2026-09-21 .. 10-31) for Workspace work outside this repo,
    # and kept on by choice when the workspace-mcp plugins were removed (2026-11-07).
    # No code here calls them; declared so the project's live API set is reproducible.
    "drive.googleapis.com" = "operator Workspace use (Drive API), kept on by choice";
    "tasks.googleapis.com" = "operator Workspace use (Tasks API), kept on by choice";
    "chat.googleapis.com" = "operator Workspace use (Chat API), kept on by choice";
    "people.googleapis.com" = "operator Workspace use (People API), kept on by choice";
    "workspacestudio.googleapis.com" = "Workspace Studio flows, kept on by choice";
    # Enabled outside this repo (compute 2026-11-20, cloudbilling 2026-11-25) and kept
    # on by choice. Declaring compute activates the depends_on hook on the service
    # map below, which orders it after the org policies that block its default
    # network and default SA. oslogin is not optional while compute is on: Google
    # refuses to disable it (measured 2026-11-18).
    "cloudbilling.googleapis.com" =
      "Cloud Billing Catalog API: operator SKU price lookups, kept on by choice";
    "compute.googleapis.com" =
      "operator-enabled, kept on by choice; default network and SA blocked by the org policies below";
    "oslogin.googleapis.com" = "required by compute: Google refuses to disable it while compute is on";
    # Google's hosted Chat MCP server (Developer Preview; project enrolled 2026-11-14),
    # reached as a claude.ai custom connector. People's MCP server rides people.googleapis.com.
    "chatmcp.googleapis.com" = "Google's Chat MCP server for the claude.ai Chat connector";
    # Found 2026-11-14 in `gcloud services list --available`: one tool, `search_corpus`,
    # searching across Gmail, Drive, Calendar and Chat. Kept on the MCP portal as a last resort.
    "workspacemcp.googleapis.com" =
      "Google's cross-app Workspace search MCP server (MCP portal, last resort)";
    # MCP portal TRIAL 2026-11-14 (infra/cloudflare/workspace-mcp-apps.nix). Maps
    # serves its MCP server from the API host itself, like People.
    "mapstools.googleapis.com" = "Maps Grounding Lite MCP server (MCP portal trial)";

    # Enabled for the Pomerium Workspace gateway on Cloud Run, RETIRED 2026-11-14
    # (replaced by infra/cloudflare/mcp-portals.nix). Nothing here uses run or
    # artifactregistry now; they stay on (free) until a deliberate API census drops
    # them. Enabling run + artifactregistry ALSO turned on pubsub and
    # containerregistry as their dependencies: measured in the audit log, which
    # shows both being disabled at the 2026-11-07 teardown with no enable event of
    # their own. Declared so a census finds every enabled API here with its reason.
    "run.googleapis.com" = "the self-hosted MCP servers (./self-hosted-mcp.nix, 2026-11-18)";
    "orgpolicy.googleapis.com" = "the project-scoped org policies below (default network, default SA)";
    "artifactregistry.googleapis.com" =
      "the ghcr.io pull-through repo the self-hosted MCP servers' image comes through";
    "containerregistry.googleapis.com" =
      "auto-enabled with run/artifactregistry (dependency, 2026-11-07 audit log)";
    "pubsub.googleapis.com" =
      "auto-enabled with run/artifactregistry (dependency, 2026-11-07 audit log)";
    # Google's hosted Workspace MCP servers, the upstreams of the Cloudflare MCP
    # portal (infra/cloudflare/mcp-portals.nix). In THIS project because the portal's
    # Google OAuth client lives here, so Google calls them on the portal's behalf
    # (chatmcp above; People's rides people.googleapis.com). All six names exist
    # (`gcloud services list --available`, 2026-11-14); that each must be ON, like
    # chatmcp, is assumed until first use.
    "gmailmcp.googleapis.com" = "Gmail MCP server, an upstream of the Cloudflare MCP portal";
    "calendarmcp.googleapis.com" = "Calendar MCP server, an upstream of the Cloudflare MCP portal";
    "drivemcp.googleapis.com" = "Drive MCP server, an upstream of the Cloudflare MCP portal";
    "docsmcp.googleapis.com" = "Docs MCP server, an upstream of the Cloudflare MCP portal";
    "sheetsmcp.googleapis.com" = "Sheets MCP server, an upstream of the Cloudflare MCP portal";
    "slidesmcp.googleapis.com" = "Slides MCP server, an upstream of the Cloudflare MCP portal";
    # Each MCP server calls its PLAIN API with this project as the quota project, so
    # that API must be on too. Measured 2026-11-14 (phone test T4): Docs and Slides
    # failed with these off; Calendar returned an empty event list. Gmail, Drive,
    # Sheets, Chat and People already had theirs (above).
    "docs.googleapis.com" = "Docs API, called by docsmcp for the Cloudflare MCP portal";
    "forms.googleapis.com" = "Forms API, called by the self-hosted forms-mcp (2026-11-18)";
    "slides.googleapis.com" = "Slides API, called by slidesmcp for the Cloudflare MCP portal";
    "calendar-json.googleapis.com" =
      "Calendar API, called by calendarmcp for the Cloudflare MCP portal";

    # Google's project defaults, on since creation (2026-07-05) with no enable event
    # in the 400-day audit log. Declared so the live API set and this map are equal:
    # a census then has nothing to explain. `disable_on_destroy = false` keeps them on.
    "analyticshub.googleapis.com" = "Google project default";
    "apptopology.googleapis.com" =
      "required by cloudapis: Google refuses to disable it while cloudapis is on (measured 2026-11-18)";
    "backupdr.googleapis.com" = "Google project default";
    "bigquery.googleapis.com" = "Google project default";
    "bigqueryconnection.googleapis.com" = "Google project default";
    "bigquerydatapolicy.googleapis.com" = "Google project default";
    "bigquerydatatransfer.googleapis.com" = "Google project default";
    "bigquerymigration.googleapis.com" = "Google project default";
    "bigqueryreservation.googleapis.com" = "Google project default";
    "bigquerystorage.googleapis.com" = "Google project default";
    "cloudapis.googleapis.com" = "Google project default";
    "cloudtrace.googleapis.com" = "Google project default";
    "dataform.googleapis.com" = "Google project default";
    "dataplex.googleapis.com" = "Google project default";
    "datastore.googleapis.com" = "Google project default";
    "logging.googleapis.com" = "Google project default";
    "monitoring.googleapis.com" = "Google project default";
    "servicemanagement.googleapis.com" = "Google project default";
    "servicenetworking.googleapis.com" = "Google project default";
    "serviceusage.googleapis.com" = "Google project default";
    "sql-component.googleapis.com" = "Google project default";
    "storage-api.googleapis.com" = "Google project default";
    "storage-component.googleapis.com" = "Google project default";
    "telemetry.googleapis.com" = "Google project default";
  };
in
{
  # The self-hosted MCP servers (Cloud Run, one per portal app with `selfHosted`).
  imports = [ ./self-hosted-mcp.nix ];

  # Version pinned exactly in ../provider-pins.nix (one place for every stack).
  terraform.required_providers.google = {
    source = "hashicorp/google";
    version = "= ${(import ../provider-pins.nix).google}";
  };

  # NO impersonation here, and that is a privilege decision rather than an
  # oversight. This stack enables APIs, manages service accounts and writes
  # project IAM — so running it as the automation account would mean granting that
  # account serviceUsageAdmin + iam.serviceAccountAdmin + projectIamAdmin, i.e.
  # the power to re-grant itself anything. Circular, and far more privilege than
  # the day-to-day stacks need.
  #
  # Instead: the FOUNDATION runs as the operator (project owner, a human at a
  # browser), and the narrow stacks run as the least-privileged service account it
  # creates. Measured 2026-09-22 — as the SA, every import here failed with
  # `accessNotConfigured` or IAM_PERMISSION_DENIED, which is the correct answer to
  # an under-privileged identity.
  provider.google = [
    { project = projectId; }
    # User ADC carries no quota project, and the Cloud Quotas API refuses such calls
    # (403 "requires a quota project", measured 2026-11-07). An ALIAS bills only the
    # resources that opt in: setting the override on the default provider billed every
    # call to this project and broke the plan on APIs it never enabled.
    {
      alias = "billed";
      project = projectId;
      user_project_override = true;
      billing_project = projectId;
    }
  ];

  # ---- Enabled services ------------------------------------------------------
  # `disable_on_destroy = false` on every one. The default is TRUE, which means a
  # `tofu destroy` — or merely removing an entry here — would DISABLE the API for
  # the whole project, taking down anything else that happened to use it. An API
  # is shared state; leaving it on costs nothing.
  # The attrset VALUE is the reason each API is on — documentation that lives
  # beside the entry instead of drifting into a comment block elsewhere.
  resource.google_project_service =
    lib.recursiveUpdate
      (lib.mapAttrs' (api: _reason: {
        name = lib.replaceStrings [ "." "-" ] [ "_" "_" ] api;
        value = {
          project = projectId;
          service = api;
          disable_on_destroy = false;
          timeouts.create = "10m";
        };
      }) services)
      (
        # Compute creates the default network and the default SA AT ENABLE TIME, so the
        # policies that forbid both must exist first. depends_on orders the API calls,
        # not enforcement, which can lag "up to 15 minutes" (Google's org-policy docs):
        # the policies land in one apply, compute in a later one.
        lib.optionalAttrs (services ? "compute.googleapis.com") {
          compute_googleapis_com.depends_on = [
            "google_org_policy_policy.skip_default_network"
            "google_org_policy_policy.no_default_sa_grants"
          ];
        }
      );

  # ---- Org policies, scoped to THIS project ----------------------------------
  # Google's own guard rails: two for what enabling Compute creates, instead of
  # deleting it afterwards, and one on API keys. Project-scoped, so the org's other
  # projects are untouched. Set by the operator, who holds roles/orgpolicy.policyAdmin
  # on the org. Each was unenforced before it was declared here
  # (`gcloud org-policies describe … --effective`).
  # The org policy API wants a quota project with user ADC, hence `google.billed`.
  resource.google_org_policy_policy =
    lib.mapAttrs
      (_: constraint: {
        provider = "google.billed";
        name = "projects/${projectId}/policies/${constraint}";
        parent = "projects/${projectId}";
        spec.rules = [ { enforce = "TRUE"; } ];
        depends_on = [ "google_project_service.orgpolicy_googleapis_com" ];
      })
      {
        skip_default_network = "compute.skipDefaultNetworkCreation";
        no_default_sa_grants = "iam.automaticIamGrantsForDefaultServiceAccounts";
        # No API key bound to a service account in THIS project. The organization
        # carries the same constraint unenforced (read 2026-11-18), and another
        # project uses such a key, so it is enforced here and not there.
        no_sa_api_keys = "iam.managed.disableServiceAccountApiKeyCreation";
      };

  # ---- Geocoding: a hard daily cap, and a key kept OUT of state ---------------
  # 31 days x 300 = 9,300 requests/month, under Google Maps Platform's 10,000 free
  # Essentials calls per month (pricing since 2025-03-01), so this API cannot bill
  # even if a script loops. The budget in budget.nix only ALERTS; this quota STOPS.
  resource.google_cloud_quotas_quota_preference.geocoding_daily_cap = {
    parent = "projects/${projectId}";
    name = "geocoding-billable-per-day";
    provider = "google.billed";
    service = "geocoding-backend.googleapis.com";
    quota_id = "BillableDefaultPerDayPerProject";
    quota_config.preferred_value = 300;
    # Unlimited -> 300 is a >10% cut, which Google refuses as "unsafe" unless told the
    # decrease is intended (FAILED_PRECONDITION, measured 2026-11-07). It is: that is the cap.
    ignore_safety_checks = "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH";
    justification = "Hard cap below the monthly free tier for operator scripts.";
    depends_on = [ "google_project_service.cloudquotas_googleapis_com" ];
  };
  # The API KEY itself is deliberately NOT declared, for the reason given for
  # service-account keys below: a declared key lands its secret in state. It was
  # created once (2026-11-07) through the API Keys REST API, restricted to
  # geocoding-backend.googleapis.com, and its value piped straight into the login
  # Keychain as `gcp:geocoding:apikey` (`secret exec GEOCODE_KEY=gcp:geocoding:apikey -- …`).
  # To rotate: create a new restricted key the same way, `secret set` it, delete the old.

  # ---- Default service accounts: no Editor ----------------------------------
  # Google grants the default compute SA roles/editor on the whole project. Nothing
  # here uses it (Compute's API is on, but no VM runs; Cloud Build, App Engine and Functions are off), so
  # it was project-wide write power held by an
  # identity no workload needs. NOT `google_project_default_service_accounts`
  # (DEPRIVILEGE): it finds default SAs by DISPLAY NAME ("compute engine default
  # service account", pdsa.go), and this one is named "Default compute service
  # account", so it would apply green and remove nothing. `iam_member_remove`
  # states the absence directly, and a re-grant (enabling Compute does that) shows
  # up as drift on the next plan.
  # The SA's email embeds the project NUMBER; read it rather than write it down.
  data.google_project.this.project_id = projectId;
  resource.google_project_iam_member_remove.default_compute_sa_editor = {
    project = projectId;
    role = "roles/editor";
    member = "serviceAccount:\${data.google_project.this.number}-compute@developer.gserviceaccount.com";
  };

  # ---- The automation identity ----------------------------------------------
  # No KEY. Nothing here creates or stores a service-account key, and this project
  # enforces `iam.managed.disableServiceAccountApiKeyCreation` (declared above).
  # That constraint covers API keys BOUND to a service account, not service-account
  # keys themselves: two accounts outside this identity hold one user-managed key
  # each (read 2026-11-18). Terraform authenticates by IMPERSONATING this account with a
  # short-lived token, which is why the binding below is the only credential that
  # matters and why there is nothing to rotate.
  resource.google_service_account.tofu_fleet = {
    project = projectId;
    account_id = saAccountId;
    display_name = "Terranix fleet automation";
    description = "Impersonated by OpenTofu. No keys: see infra/gcp/foundation.nix.";
  };

  # ---- The Workspace domain-admin identity ----------------------------------
  # Declared so it stops being invisible: it existed since 2026-09-07 and NOTHING
  # in this repo mentioned it until ADR-005 phase 4 went looking.
  #
  # ONLY the account is managed here. Its power is not: domain-wide delegation is
  # granted in the Workspace ADMIN CONSOLE (client id + OAuth scopes), which no
  # Terraform provider can reach — `hashicorp/terraform-provider-googleworkspace`
  # was archived 2025-06-30. That boundary is the whole reason ADR-005 keeps
  # Workspace as a runbook, and docs/workspace-runbook.md is that runbook.
  #
  # It has NO user-managed key, and should not regain one: the last was deleted
  # 2026-09-22 (docs/workspace-runbook.md §2) once the Admin console confirmed no
  # delegation was ever registered to it. Terraform must never manage one either —
  # a declared key means the private material lands in state.
  #
  # The SYSTEM_MANAGED key Google rotates is a different thing and is what makes
  # impersonation work. Leave it.
  #
  # IN USE SINCE 2026-11-15, for ONE job (ADR-005 § 3.3's narrow reopening): Chrome
  # browser policy on the organizational unit that holds enrolled browsers. It holds
  # a Chrome-only custom admin role, assigned to it DIRECTLY in the Admin console and
  # restricted to that unit. Still NO domain-wide delegation: delegation would let it
  # act as the super admin, and this job never needs that. The `account_id` is
  # immutable and predates the job, so the NAME overstates the power — the display
  # name and description below say what is true instead.
  resource.google_service_account.ws_domain_admin = {
    project = projectId;
    account_id = wsDomainAdminAccountId;
    display_name = "Chrome browser policy automation (one unit only)";
    # The description is the FIX for the finding, not decoration. It first read
    # "Domain-wide delegation for Admin SDK domain + site verification", an
    # intention never carried out, which reads to an auditor as authority that
    # exists. Then "UNUSED" (2026-09-22). Say what is true NOW.
    description = "Chrome policy on one organizational unit, by a unit-restricted Chrome-only admin role. No domain-wide delegation, no project roles, no user-managed key. See docs/workspace-runbook.md.";
  };

  # The operator mints a 1-hour token for it; nothing else can. Revoke THIS to cut
  # the Chrome policy lane off without touching the Admin console.
  resource.google_service_account_iam_member.operator_token_creator_ws = {
    service_account_id = "\${google_service_account.ws_domain_admin.name}";
    role = "roles/iam.serviceAccountTokenCreator";
    member = "user:${operatorAccount}";
  };

  # Lets the service account be used as a quota/consumer identity on the project.
  resource.google_project_iam_member.tofu_service_usage = {
    project = projectId;
    role = "roles/serviceusage.serviceUsageConsumer";
    member = "serviceAccount:${automationServiceAccount}";
  };

  # Budget read/write on the billing account. costsManager, NOT billing.admin:
  # this identity needs to manage a spend ALERT, not to link projects, close the
  # account, or change payment details.
  resource.google_billing_account_iam_member.tofu_costs_manager = {
    billing_account_id = billingAccountId;
    role = "roles/billing.costsManager";
    member = "serviceAccount:${automationServiceAccount}";
  };

  # The one grant that makes impersonation possible, and therefore the one to
  # revoke if this Mac is ever lost: without it the operator cannot mint a token
  # for the automation account at all.
  resource.google_service_account_iam_member.operator_token_creator = {
    service_account_id = "\${google_service_account.tofu_fleet.name}";
    role = "roles/iam.serviceAccountTokenCreator";
    member = "user:${operatorAccount}";
  };

  # ---- The operator's own grants ---------------------------------------------
  # Declared so a hand edit shows up as drift. MEMBER resources, never the
  # authoritative `_iam_policy`/`_iam_binding`: those would strip every grant not
  # listed here. prevent_destroy because removing either is a self-lockout.
  resource.google_project_iam_member.operator_owner = {
    project = projectId;
    role = "roles/owner";
    member = "user:${operatorAccount}";
    lifecycle.prevent_destroy = true;
  };

  resource.google_billing_account_iam_member.operator_billing_admin = {
    billing_account_id = billingAccountId;
    role = "roles/billing.admin";
    member = "user:${operatorAccount}";
    lifecycle.prevent_destroy = true;
  };

  # ---- Who may create billing accounts and projects: the operator only -------
  # Google grants roles/billing.creator and roles/resourcemanager.projectCreator to
  # `domain:<workspace domain>` when an organization is created, so every account
  # in the domain can open a billing account, attach a payment method and create
  # projects. Read 2026-11-18: on both roles that domain grant was the ONLY member,
  # and the console's billing health check flags the billing one.
  #
  # The only AUTHORITATIVE bindings in this stack, on purpose: one per role in
  # `operatorOnlyOrgRoles`, and for those roles only. The rule above (MEMBER
  # resources, never `_iam_binding`) exists because a binding strips every member it
  # does not list. Here that stripping IS the change: a re-grant to the domain, or
  # to anyone else, shows as drift on the next plan.
  # Not `_iam_member_remove`: the pinned provider (8.4.0) ships that for PROJECTS
  # only (`tofu providers schema`, read 2026-11-18), and `_iam_policy` would own
  # every role on the organization.
  #
  # UNDOING IT: deleting a role here does NOT restore the domain. Removing an
  # `_iam_binding` destroys the whole binding, so the role would end with no
  # member. To give the domain a role back, add it to `members`. And never add
  # a `google_organization_iam_member` for these roles anywhere: the two resources
  # would undo each other on alternate applies.
  #
  # The organization is found by the operator account's domain, so no org id is
  # written here. The default provider, not `google.billed`: Cloud Resource Manager
  # is not enabled on the project, and a call that names it as quota project is
  # refused (403 "has not been used in project", measured 2026-11-18).
  data.google_organization.this.domain = lib.last (lib.splitString "@" operatorAccount);

  # The operator's remaining organization grants (all three read live 2026-11-18,
  # each with the operator as its only member). MEMBER resources, unlike the two
  # roles above: these are the grants that let the operator repair everything else,
  # so nothing here may ever strip one. prevent_destroy for the same reason.
  resource.google_organization_iam_member = lib.mapAttrs (_: role: {
    org_id = "\${data.google_organization.this.org_id}";
    inherit role;
    member = "user:${operatorAccount}";
    lifecycle.prevent_destroy = true;
  }) operatorOrgGrants;

  # Adopt each existing binding instead of creating over it, so the plan SHOWS the
  # domain leaving rather than a bare "+ create". A no-op once it is in state.
  import =
    lib.mapAttrsToList (name: role: {
      to = "google_organization_iam_binding.${name}";
      id = "\${data.google_organization.this.org_id} ${role}";
    }) operatorOnlyOrgRoles
    ++ lib.mapAttrsToList (name: role: {
      to = "google_organization_iam_member.${name}";
      id = "\${data.google_organization.this.org_id} ${role} user:${operatorAccount}";
    }) operatorOrgGrants;

  resource.google_organization_iam_binding = lib.mapAttrs (_: role: {
    org_id = "\${data.google_organization.this.org_id}";
    inherit role;
    members = [ "user:${operatorAccount}" ];
  }) operatorOnlyOrgRoles;

  # The project's default log bucket, at Google's default 30-day retention. The
  # `_Required` bucket is locked by Google and cannot be managed.
  resource.google_logging_project_bucket_config.default = {
    project = projectId;
    location = "global";
    bucket_id = "_Default";
    retention_days = 30;
  };

  # ---- OpenTofu state bucket (ADR-005 phase 1) -------------------------------
  resource.google_storage_bucket.tofu_state = {
    project = projectId;
    name = stateBucket;
    # us-central1 is one of the three regions Always Free covers (with us-west1
    # and us-east1), and state is kilobytes, so this stays inside the free tier
    # and therefore inside the 5 CAD alert.
    location = stateBucketLocation;
    storage_class = "STANDARD";

    # THE reason to use a bucket at all. Terraform state is the one file where
    # "restore yesterday's copy" is the difference between a bad afternoon and
    # re-importing an entire account. State has been lost twice in this fleet.
    versioning.enabled = true;

    # No ACLs, IAM only — ACLs are a second, older permission system that can
    # silently widen access behind the IAM policy you are actually reading.
    uniform_bucket_level_access = true;
    public_access_prevention = "enforced";

    # State holds the tunnel connector token (inside client-side state encryption).
    # Deleting this bucket is therefore never a routine action.
    lifecycle.prevent_destroy = true;

    # Keep 10 non-current versions, then stop paying for history nobody reads.
    lifecycle_rule = [
      {
        condition = {
          num_newer_versions = 10;
          with_state = "ARCHIVED";
        };
        action.type = "Delete";
      }
    ];
  };

  # ---- Grafana long-term history (ADR-011 step 11) -------------------------
  # Grafana keeps 14-31 days, so a daily GitHub Actions job copies one row of KPI
  # aggregates into a Drive Sheet (a STORE only), and Grafana's Sheets datasource reads
  # it back. Two identities, so the one with a key can only READ:
  #
  #   writer: NO key. GitHub Actions proves itself via OIDC -> this pool -> a 1 h token.
  #   reader: ONE key, created out-of-band straight into Grafana (a key declared here
  #           would put the private material in state). Never granted a project role.
  #
  # Neither holds a project role: each reaches the Sheet only because the Sheet is
  # shared with its email (docs/workspace-runbook.md: Workspace has no live provider).
  resource.google_iam_workload_identity_pool.github = {
    project = projectId;
    workload_identity_pool_id = "github";
    display_name = "GitHub Actions";
    description = "OIDC from GitHub Actions; only ${rollupRepo}@main is accepted (ADR-011 step 11).";
    # A destroy soft-deletes it for 30 days (the id stays locked) and, for the reader,
    # silently kills the key Grafana holds.
    lifecycle.prevent_destroy = true;
  };

  resource.google_iam_workload_identity_pool_provider.github_actions = {
    project = projectId;
    workload_identity_pool_id = "\${google_iam_workload_identity_pool.github.workload_identity_pool_id}";
    workload_identity_pool_provider_id = "github-actions";
    display_name = "GitHub Actions OIDC";
    attribute_mapping = {
      "google.subject" = "assertion.sub";
      "attribute.repository" = "assertion.repository";
      "attribute.ref" = "assertion.ref";
      # What the writer's binding keys on (below): the exact workflow FILE, not the repo.
      "attribute.workflow_ref" = "assertion.job_workflow_ref";
    };
    # Five clauses, all required. repository + ref alone admitted claude.yml (issue_comment
    # runs on main with id-token: write), flakehub-publish and build-installers
    # (terranix-infra-reviewer, 2026-11-03). Pinning the WORKFLOW FILE admits only the
    # rollup; the numeric ids survive a repo or org rename, which the name does not.
    attribute_condition = lib.concatStringsSep " && " [
      "assertion.repository_id == '1276523163'"
      "assertion.repository_owner_id == '305065254'"
      "assertion.repository == '${rollupRepo}'"
      "assertion.ref == 'refs/heads/main'"
      "assertion.job_workflow_ref == '${rollupRepo}/.github/workflows/grafana-rollup.yml@refs/heads/main'"
    ];
    oidc.issuer_uri = "https://token.actions.githubusercontent.com";
    lifecycle.prevent_destroy = true;
  };

  resource.google_service_account.grafana_rollup_writer = {
    project = projectId;
    account_id = rollupWriterAccountId;
    display_name = "Grafana rollup writer (GitHub Actions)";
    description = "No keys. Impersonated only via the github WIF pool from ${rollupRepo}@main. Edits the history Sheet it is shared on (ADR-011 step 11).";
    # A destroy soft-deletes it for 30 days (the id stays locked) and, for the reader,
    # silently kills the key Grafana holds.
    lifecycle.prevent_destroy = true;
  };

  resource.google_service_account_iam_member.grafana_rollup_writer_wif = {
    service_account_id = "\${google_service_account.grafana_rollup_writer.name}";
    role = "roles/iam.workloadIdentityUser";
    # Keyed on the WORKFLOW FILE, not the repository: the provider's condition already pins
    # it, but a binding on attribute.repository would let every workflow in the repo
    # impersonate the writer the day a looser provider joins this pool. Two locks, each
    # sufficient on its own (terranix-infra-reviewer, 2026-11-03).
    member = "principalSet://iam.googleapis.com/\${google_iam_workload_identity_pool.github.name}/attribute.workflow_ref/${rollupRepo}/.github/workflows/grafana-rollup.yml@refs/heads/main";
  };

  resource.google_service_account.grafana_sheets_reader = {
    project = projectId;
    account_id = "grafana-sheets-reader";
    display_name = "Grafana Sheets reader";
    description = "ONE key, held only by the Grafana Sheets datasource (not in state). Viewer on the history Sheet only (ADR-011 step 11).";
    # A destroy soft-deletes it for 30 days (the id stays locked) and, for the reader,
    # silently kills the key Grafana holds.
    lifecycle.prevent_destroy = true;
  };

  # ---- Grafana reads Cloud Monitoring (Maps Platform usage) ------------------
  # The Grafana `gcp-monitoring` datasource (infra/grafana/) queries Cloud
  # Monitoring ON DEMAND, so Maps request counts, errors, latency and the quota limit cost
  # zero Grafana series. Same key model as the Sheets reader above: ONE key, created
  # out-of-band and sent straight into the datasource, never in state or on disk. To
  # rotate: mint a new key the same way, PUT it into the datasource, delete the old key.
  # Rejected: Workload Identity Federation for the datasource, which is per signed-in
  # user in Grafana Cloud and so breaks alert evaluation (ADR-011 step 11).
  resource.google_service_account.grafana_monitoring_reader = {
    project = projectId;
    account_id = "grafana-monitoring-reader";
    display_name = "Grafana Cloud Monitoring reader";
    description = "ONE key, held only by the Grafana gcp-monitoring datasource (not in state). monitoring.viewer only.";
    # A destroy soft-deletes it for 30 days and silently kills the key Grafana holds.
    lifecycle.prevent_destroy = true;
  };

  # monitoring.viewer, the least role that reads time series and metric descriptors.
  # Not monitoring.editor (writes), not roles/viewer (every resource in the project).
  resource.google_project_iam_member.grafana_monitoring_reader_viewer = {
    project = projectId;
    role = "roles/monitoring.viewer";
    member = "serviceAccount:\${google_service_account.grafana_monitoring_reader.email}";
  };

  # The same role on the Workspace add-on's project, the ONE thing this stack touches
  # there: its Apps Script logs and API calls are counted in that project's Cloud
  # Monitoring, which the reader could not see (read 2026-11-18). A member resource, so
  # that project's other grants are never rewritten.
  resource.google_project_iam_member.grafana_monitoring_reader_addon_viewer = {
    project = addonProjectId;
    role = "roles/monitoring.viewer";
    member = "serviceAccount:\${google_service_account.grafana_monitoring_reader.email}";
  };

  output.wif_provider.value = "\${google_iam_workload_identity_pool_provider.github_actions.name}";
  output.grafana_rollup_writer.value = "\${google_service_account.grafana_rollup_writer.email}";
  output.grafana_sheets_reader.value = "\${google_service_account.grafana_sheets_reader.email}";
  output.state_bucket.value = "\${google_storage_bucket.tofu_state.name}";
  output.automation_sa.value = automationServiceAccount;
}
