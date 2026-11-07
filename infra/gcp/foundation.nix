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
  ...
}:
let
  # The short name, as `google_service_account` wants it — the resource takes an
  # account_id, not the full email, while every IAM binding takes the email.
  saAccountId = lib.head (lib.splitString "@" automationServiceAccount);

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
    "gmail.googleapis.com" = "gmailctl's filter sync (packages/gmail-filters.nix), operator ADC";
    "admin.googleapis.com" = "Admin SDK, enabled 2026-09-07 with ws_domain_admin below";
    # Operator-enabled by hand (2026-09-21 .. 10-31) for Workspace work outside this repo,
    # and kept on by choice when the workspace-mcp plugins were removed (2026-11-07).
    # No code here calls them; declared so the project's live API set is reproducible.
    "drive.googleapis.com" = "operator Workspace use (Drive API), kept on by choice";
    "tasks.googleapis.com" = "operator Workspace use (Tasks API), kept on by choice";
    "chat.googleapis.com" = "operator Workspace use (Chat API), kept on by choice";
    "people.googleapis.com" = "operator Workspace use (People API), kept on by choice";
    "workspacestudio.googleapis.com" = "Workspace Studio flows, kept on by choice";

    # Google's project defaults, on since creation (2026-07-05) with no enable event
    # in the 400-day audit log. Declared so the live API set and this map are equal:
    # a census then has nothing to explain. `disable_on_destroy = false` keeps them on.
    "analyticshub.googleapis.com" = "Google project default";
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
  provider.google.project = projectId;

  # ---- Enabled services ------------------------------------------------------
  # `disable_on_destroy = false` on every one. The default is TRUE, which means a
  # `tofu destroy` — or merely removing an entry here — would DISABLE the API for
  # the whole project, taking down anything else that happened to use it. An API
  # is shared state; leaving it on costs nothing.
  # The attrset VALUE is the reason each API is on — documentation that lives
  # beside the entry instead of drifting into a comment block elsewhere.
  resource.google_project_service = lib.mapAttrs' (api: _reason: {
    name = lib.replaceStrings [ "." "-" ] [ "_" "_" ] api;
    value = {
      project = projectId;
      service = api;
      disable_on_destroy = false;
      timeouts.create = "10m";
    };
  }) services;

  # ---- Default service accounts: no Editor ----------------------------------
  # Google grants the default compute SA roles/editor on the whole project. Nothing
  # here uses it (Compute, Cloud Build, App Engine and Functions are all off), so
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
  # No KEY. Nothing here creates or stores a service-account key, and the org
  # policy `constraints/iam.managed.disableServiceAccountApiKeyCreation` is
  # already in force. Terraform authenticates by IMPERSONATING this account with a
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
  resource.google_service_account.ws_domain_admin = {
    project = projectId;
    account_id = "ws-domain-admin";
    display_name = "Workspace Domain Admin (fleet automation)";
    # The description is the FIX for the finding, not decoration. It previously
    # read "Domain-wide delegation for Admin SDK domain + site verification",
    # which described an intention that was never carried out — and which reads to
    # an auditor as authority that exists. No delegation was ever registered
    # (verified 2026-09-22 in the Admin console). Say what is true.
    description = "UNUSED as of 2026-09-22: no domain-wide delegation registered, no project roles, no user-managed key. See docs/workspace-runbook.md before granting it anything.";
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

  output.wif_provider.value = "\${google_iam_workload_identity_pool_provider.github_actions.name}";
  output.grafana_rollup_writer.value = "\${google_service_account.grafana_rollup_writer.email}";
  output.grafana_sheets_reader.value = "\${google_service_account.grafana_sheets_reader.email}";
  output.state_bucket.value = "\${google_storage_bucket.tofu_state.name}";
  output.automation_sa.value = automationServiceAccount;
}
