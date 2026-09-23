# infra/cloudflare/access-org.nix — the Zero Trust ORGANISATION, and its login page.
#
# WHY THIS IS ITS OWN STACK, and not a few lines added to mcp-public.nix:
# a stack is a blast radius, not a category (ADR-005 §4). This object sits ABOVE
# both Cloudflare stacks — `auth_domain` is the sign-in host for EVERY Access
# application in the account, so breaking it takes out nixpi's SSH gate and the
# MCP portal in the same apply. It shares no failure mode with a tunnel or with a
# DNS record, and it must not ride in a plan whose other half is either of those.
#
# WHAT IT IS FOR, concretely: the login page's branding. That page is the only
# surface in the whole connector flow that carries the operator's mark — Claude
# renders a generic globe for every custom connector, and neither MCP nor
# Cloudflare gives us a way to change it (see `accessOrg` in
# modules/parts/identity.nix for the measured detail).
#
# ============================ THE DANGEROUS PART ============================
# `cloudflare_zero_trust_organization` models the ENTIRE organisation, and every
# single one of its attributes is OPTIONAL in the provider schema — verified
# against v5.25.0's own source (model.go / encoder.go), not from the registry
# docs, which are stale for this resource in at least one other respect (they
# claim it does not support `terraform import`; resource.go:229 implements it).
# There is no "manage only login_design" mode. So a render that declares nothing
# but the branding is NOT a safe subset — it is a description of an organisation
# whose other fields are unset, and the provider will happily send that.
#
# `auth_domain` is the one that turns a cosmetic change into an outage. This repo
# has already lost an Access object once (2026-08-20) and it took `ssh` and both
# deploy legs with it.
#
# So this module MIRRORS the live organisation rather than patching it. The rule
# for editing it is therefore the opposite of the usual one — do not "clean up" a
# field you are not using. An omission here is an instruction to blank it.
#
# WHY AN OMISSION IS A BLANKING, from the provider's encoder rather than from
# folklore (internal/apijson/encoder.go:406-409 @ v5.25.0):
#
#     if stateNull && planNull   { return nil, nil }              // omit the key
#     } else if planNull         { return explicitJsonNull, nil }  // send null
#
# and Update marshals against prior state (resource.go:129,
# `data.MarshalJSONForUpdate(*state)`). Read together: an attribute that STATE
# holds non-null and this render omits is sent as an explicit JSON `null` — a
# delete, not a no-op. An attribute null in both is simply omitted, which is why
# a field that is unset live is safe to leave out.
#
# `computed_optional` attributes are exempt: the framework fills them from prior
# state, so absence never becomes null. Per model.go those are
# allow_authenticate_via_warp, auto_redirect_to_identity, is_ui_read_only,
# mfa_configuration_allowed, mfa_required_for_all_apps, ui_read_only_toggle_reason
# and warp_auth_non_browser_401.
#
# THE SIX THAT ARE NOT EXEMPT, and are not declared below because they are unset
# live: session_duration, user_seat_expiration_inactive_time,
# warp_auth_session_duration, custom_pages, mfa_config,
# mfa_ssh_piv_key_requirements. "Unset live" is an observation with a shelf life —
# set any of them in the dashboard and the next apply DELETES it. That is not left
# to this comment: `mkCfAccessOrgTofu` reads them back out of state and refuses
# the run, so the guard fails rather than the org.
#
# IMPORT, NEVER CREATE. There is exactly one organisation per account and it has
# existed since 2026-07-03. The apply wrapper refuses an empty state for this
# reason; import with the account id:
#   tofu import cloudflare_zero_trust_organization.fleet <accountId>
#
# Fields in the live API response that this resource does NOT model —
# `cache_device_posture`, `service_token_inactivity`, `trusted_accounts`,
# `has_migrated_private_apps` — are absent from its schema entirely. They are not
# omissions to fix here; there is nowhere to put them.
#
# A PLAN CANNOT TELL YOU WHETHER THEY SURVIVE. The plan is rendered from the
# schema, and these have no slot in it — so a clean plan confirms nothing about
# them, and reading it as reassurance is the trap. What IS settled from source:
# the provider marshals only `ZeroTrustOrganizationModel`, so it never emits
# these keys at all, as a value or as a null. What is NOT settled anywhere on
# this side: whether Cloudflare's PUT treats an absent key as "leave alone" or
# "reset to default". That is server behaviour.
#
# The only evidence that answers it is a before/after GET of
# /accounts/<id>/access/organizations around the first apply. If any of the four
# moves, this resource is not safely manageable as configured — detach it
# (`tofu state rm`, which touches nothing at Cloudflare) rather than iterating.
{
  accountId,
  # The login page's content, from modules/parts/identity.nix. REQUIRED, not
  # defaulted: a `? { }` would render a branding-free login page, which is a
  # silent un-branding rather than an error. Same reasoning as `dnsRecords` in
  # zones.nix.
  loginDesign,
  # Mirrored organisation state. REQUIRED for the same reason, and with sharper
  # teeth: `authDomain` unset would blank the sign-in host for every Access
  # application in the account.
  authDomain,
  orgName,
  ...
}:
{
  # PINNED, not floored — and this is the one module in the tree where that is
  # load-bearing rather than tidy. Every safety claim above is a reading of
  # 5.25.0's encoder and model; a provider bump can re-derive all of them. The
  # sibling stacks survive a bump because their resources fail loudly; this one
  # fails by silently sending a null. `.terraform.lock.hcl` lives in the state
  # dir, outside git, so the lock is NOT the pin — this is.
  terraform.required_providers.cloudflare = {
    source = "cloudflare/cloudflare";
    version = "= 5.25.0";
  };

  provider.cloudflare = { };

  resource.cloudflare_zero_trust_organization.fleet = {
    account_id = accountId;

    # ---- Mirrored, NOT configured here --------------------------------------
    # These four are what the account already has. They are written down so the
    # render is a faithful description of the live object; changing one is a real
    # change to how Access behaves, not a tidy-up.
    name = orgName;
    auth_domain = authDomain;
    is_ui_read_only = false;
    # An empty list is meaningful: it is the live value, and it pairs with
    # deny_unmatched_requests = false. Both are the permissive defaults.
    deny_unmatched_requests = false;
    deny_unmatched_requests_exempted_zone_names = [ ];
    allow_authenticate_via_warp = false;
    warp_auth_non_browser_401 = false;

    # ---- The actual point of this stack -------------------------------------
    # `text_color` is deliberately absent: it is unset live, and the login page
    # picks a readable default against `background_color`. Setting it to "" would
    # not be the same thing.
    #
    # Safe only WHILE it is null in state. `login_design` is declared, so it is
    # encoded field by field under the same rule as the top level: null in both
    # plan and state means the key is omitted. Set a text colour in the dashboard
    # and the next apply reverts it — same class as the six above, smaller blast
    # radius.
    login_design = {
      logo_path = loginDesign.logoUrl;
      background_color = loginDesign.backgroundColor;
      header_text = loginDesign.headerText;
      footer_text = loginDesign.footerText;
    };
  };

  # Surfaced so the apply wrapper can assert the sign-in host it is about to
  # write, without the operator having to read the rendered JSON. This is the
  # field whose loss is an outage, so it is the one worth printing.
  output.auth_domain.value = authDomain;
  output.logo_path.value = loginDesign.logoUrl;
}
