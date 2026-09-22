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
# state, in its own pinned directory, and the other four move to GCS.
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
    "storage.googleapis.com" = "the OpenTofu state bucket below";
  };
in
{
  terraform.required_providers.google.source = "hashicorp/google";

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

    # State holds tunnel connector tokens and an Access service-token secret in
    # plaintext today. Deleting this bucket is therefore never a routine action.
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

  output.state_bucket.value = "\${google_storage_bucket.tofu_state.name}";
  output.automation_sa.value = automationServiceAccount;
}
