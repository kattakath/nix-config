# ---- GCP billing budget (terranix -> OpenTofu) -----------------------------
#
# ADR-005 phase 3's first object, and deliberately the first: billing came before
# anything that could spend.
#
# READ THIS BEFORE TRUSTING IT
# ============================
# **A budget is an ALERT, not a CAP.** It emails at thresholds. It does not stop
# spending, does not disable an API, and does not close the account. Google offers
# NO hard spending limit on a billing account — the only real cap anyone builds is
# a Pub/Sub topic feeding a Cloud Function that calls
# `projects.updateBillingInfo` with an empty billing account, which takes the
# project's services down with it. That is not wired here, on purpose: the fleet's
# only intended GCP spend is Terraform state (kilobytes, inside Always Free), so
# the realistic bill is $0 and the useful instrument is an early warning, not a
# kill switch.
#
# If the alert ever fires, the question to ask is "what started spending?" — not
# "why did the cap not hold?", because there is no cap.
#
# WHY TERRANIX AND NOT THE CONSOLE
# ================================
# A budget clicked into the Console is invisible to review and silently deleted by
# whoever clicks next. Declared here it is diffable, and the amount is a
# single-sourced fleet constant rather than a number someone remembers typing.
{
  lib,
  billingAccountId,
  # Single digit by operator instruction (2026-09-22). `units` is a STRING in the
  # API: google.type.Money uses int64 units, which JSON carries as a string.
  budgetAmount,
  # MUST match the billing account's currency — a mismatch is rejected as a bare
  # 400 with no field violation naming currency. See identity.nix.
  budgetCurrency,
  # The service account terraform IMPERSONATES. Not a key file, and not the
  # operator's own ADC:
  #
  #   * user ADC fails here. Measured 2026-09-22: the billingbudgets API refuses
  #     user credentials without a quota project, and STILL 403s on
  #     `serviceusage.services.use` after `set-quota-project` and with
  #     roles/owner held DIRECTLY on the project. gcloud's own credential got
  #     past auth on the same call, so it is the ADC path specifically.
  #   * a key file would be a long-lived secret on disk, which this repo does not
  #     do for anything else either.
  #
  # Impersonation is the remaining option and the standard one: the operator
  # holds roles/iam.serviceAccountTokenCreator on this SA and mints a short-lived
  # token per run. Nothing to rotate, nothing to leak.
  automationServiceAccount,
  ...
}:
let
  # Threshold rules fire at a percentage of the budget. CURRENT spend only here —
  # FORECASTED is deliberately added as a separate rule below, because the two
  # answer different questions: "you have spent half" vs "you are on track to
  # exceed". The forecast one is what gives you time to act.
  currentThresholds =
    map
      (pct: {
        threshold_percent = pct;
        spend_basis = "CURRENT_SPEND";
      })
      [
        0.5
        0.9
        1.0
      ];

  forecastThresholds = [
    {
      threshold_percent = 1.0;
      spend_basis = "FORECASTED_SPEND";
    }
  ];
in
{
  terraform.required_providers.google.source = "hashicorp/google";

  # No `project`, no `region`: a budget hangs off the BILLING ACCOUNT, which is
  # above any project. Credentials come from ADC — and, per the devShell's
  # CLOUDSDK_CONFIG, from the repo-scoped gcloud config dir rather than whichever
  # account happens to be globally active.
  provider.google = {
    impersonate_service_account = automationServiceAccount;
  };

  resource.google_billing_budget.fleet = {
    billing_account = billingAccountId;
    display_name = "fleet-budget-${budgetAmount}-${lib.toLower budgetCurrency}";

    # No `budget_filter.projects`: the budget covers the WHOLE billing account, so
    # a project added later is inside it by default rather than by remembering to
    # extend a filter. Deny-by-omission is the wrong default for a spend alarm.
    budget_filter = {
      calendar_period = "MONTH";
    };

    amount.specified_amount = {
      currency_code = budgetCurrency;
      units = budgetAmount;
    };

    threshold_rules = currentThresholds ++ forecastThresholds;

    # NO `all_updates_rule`. Measured 2026-09-22: the API answers
    # `400 Request contains an invalid argument` for a rule that carries only
    # `disable_default_iam_recipients` — that block is meaningful only alongside a
    # Monitoring channel or a Pub/Sub topic, neither of which exists here.
    #
    # Omitting it is also the behaviour we want: with no rule, Google emails
    # every billing-account admin and user by default, which is the operator. A
    # Monitoring channel would add a second API, a second resource and a second
    # thing to keep alive to deliver the same email.
  };

  output.budget_name.value = "\${google_billing_budget.fleet.name}";
  output.budget_amount.value = "${budgetAmount} ${budgetCurrency}";
}
