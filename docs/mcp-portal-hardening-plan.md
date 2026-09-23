# MCP portal hardening — the verified plan

Produced 2026-09-23 by a 13-agent research + adversarial-refutation pass over
`infra/cloudflare/mcp-public.nix`, the Cloudflare One docs and this repo's own gates.
Every attribute name below survived a refutation round whose first job was to hunt
invented ones; anything still ungrounded is marked **UNVERIFIED** with what would
settle it.

**Two of the four items shipped** — `#596` (token expiry as a checked fact) and
`#597` (per-server policy tiers). The other two did not, and the reasons are the
most reusable part of this document:

| # | Item | Outcome |
|---|---|---|
| 0 | Pin the provider | **Held** — ADR-004 already deferred it; needs a plan run |
| 1 | Token expiry as a checked fact | **Shipped** (#596) |
| 2 | Per-server policy tiers | **Shipped** (#597) |
| 3 | Device posture on sensitive servers | **Declined** — zero enrolled devices |
| 4 | Ephemeral worker end-to-end | **Blocked** on a live measurement |

---


## Verdict first

| # | Item | Do it? | Why |
|---|---|---|---|
| 0 | **Pin the provider** in `mcp-public.nix` | **YES — first** | Every schema fact below is a fact about **one version**. This stack pins **nothing** today. |
| 1 | **Token expiry as a checked fact** | **YES** | Zero-risk. `duration` is an **in-place update**, not a replacement. Nothing goes dark. |
| 2 | **Per-server policy tiers** | **YES, narrowly** | Buys structure before the second human exists. Buys **no isolation today**. One silent way to lock yourself out of all 26. |
| 3 | **Device posture on sensitive servers** | **NO — do not do this** | Zero enrolled devices. A `device_posture` require evaluates **false forever** and takes the tier **offline**. |
| 4 | **Ephemeral worker end-to-end** | **NOT YET** | The tier boundary is a **documented discovery filter**, not a documented authorization boundary. Measure before you rely on it. |

**The one sentence that governs all four:** none of this closes the direct-URL hole. Anyone holding the `mcp_public` service token reaches `https://upstream.kattakath.com/servers/<name>/mcp` for **all 26**, regardless of every policy below. Cloudflare says so explicitly. `infra/cloudflare/mcp-public.nix:35-41` already recorded that acceptance.

---

## Order of landing

```
┌─────────────────────────────┐
│ 0  pin provider  (own PR)   │
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 1  duration + check + banner│  independent, zero-risk
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 2  policy tiers  (own PR)   │  apply-gated, read the plan
└──────────────┬──────────────┘
               │
┌──────────────▼──────────────┐
│ 4  worker  — MEASURE FIRST  │  do not ship on inference
└─────────────────────────────┘

  3  device posture  — NOT ON THE PATH. Do not start.
```

---

# 0. Pin the provider — prerequisite, own PR

**Why:** `infra/cloudflare/mcp-public.nix` has **no `terraform.required_providers` block**. Verified: the block exists only in `access-org.nix:103`, `nixpi-tunnel.nix:235`, `zones.nix:59`. The stack owning **all 26 published servers** is the one stack with no pin.

**LOUD — do NOT add `source = "cloudflare/cloudflare"`.** That stack's lockfile records the legacy address `registry.opentofu.org/hashicorp/cloudflare`. Changing `source` moves the **provider address in state**, which needs `tofu state replace-provider` — **state surgery on an encrypted GCS backend, with no flake app lane for it** (`modules/parts/terranix.nix:1143` is `tofu ${action} "$@"`, action fixed to plan|apply|destroy).

**Version-only is the cheap fix** — it keeps the inferred legacy address:

```nix
  # Pin the VERSION, not the source. Every schema fact this file leans on —
  # `duration` defaulting to 8760h, and that changing it is an in-place update
  # rather than a replacement — is a fact about ONE provider release.
  #
  # `source` is deliberately absent: this stack's lock already records the
  # inferred legacy address (registry.opentofu.org/hashicorp/cloudflare), and
  # naming cloudflare/cloudflare here would move the provider address in state,
  # which needs `tofu state replace-provider` — surgery no flake app can run.
  terraform.required_providers.cloudflare.version = "= 5.25.0";
```

- **UNVERIFIED:** that a `version`-only entry plans as a clean no-op here. **What verifies it:** `nix run .#mcp-public-plan` — `tofu init` must not ask to change providers.
- Repo-only otherwise. **No apply needed** if the plan reads `0 to change`.
- **PR title:** `apps`

---

# 1. Token expiry as a checked fact — safest, land next

## 1a. The fact that makes this safe

| Fact | Value | Source |
|---|---|---|
| `duration` | Optional+Computed, `Default("8760h")` | `zero_trust_access_service_token/schema.go:79-83` @ v5.25.0 |
| Format | Go duration (`2h45m`) **or** `forever`; **no provider validator** | same Description |
| **ForceNew?** | **NO** — only `account_id` (`:42`) and `zone_id` (`:47`) carry `RequiresReplace()` | schema.go |
| Update behaviour | `PUT` same token id; provider **preserves the old `client_secret`** | `resource.go:105,124,160-163` |
| Renewal semantics | Cloudflare **resets expiry relative to the update** | developers.cloudflare.com service-tokens |

**Consequence:** `client_id`/`client_secret` do not move → `tokenHeaders` (`mcp-public.nix:300`) does not move → the 26 `auth_credentials` see **no diff** → **no re-registration, no dark window**.

**Two traps, stated plainly:**
- Declaring `8760h` today is a **zero-diff no-op** — that is the point, and it also means **re-applying an unchanged value renews nothing** (no diff, no PUT). Renewal needs a **changed** value.
- Rotation is **structurally two fields away**, not one: `client_secret_version` and `previous_client_secret_expires_at` each `AlsoRequires` the other (`schema.go:58-77`). A lone version bump is a config-validation error, never a silent rotation.

## 1b. The render change — replace `infra/cloudflare/mcp-public.nix:347-357`

```nix
  # ---- (e) The service token -------------------------------------------------
  # `duration` is DECLARED, not inherited. Omitting it does not avoid an expiry:
  # the provider defaults it to 8760h (zero_trust_access_service_token/schema.go
  # :79-83 @ 5.25.0), so the first apply (2026-09-12) silently minted one valid
  # until 2027-09-12. This is the portal's ONLY credential, so when it lapses
  # EVERY published server goes dark at once, with no partial failure first.
  #
  # CHANGING it is an IN-PLACE update, never a replacement: `duration` carries no
  # RequiresReplace plan modifier (only account_id/zone_id do, schema.go:42,47),
  # Update PUTs the same token id, and the provider explicitly keeps the old
  # client_secret when the API returns none (resource.go:160-163). So the portal
  # headers above never move and nothing goes dark. Only a rotation moves the
  # secret, and a rotation is two fields away, not one: client_secret_version and
  # previous_client_secret_expires_at each AlsoRequires the other (:58-77).
  #
  # Cloudflare resets the expiry RELATIVE TO THE UPDATE, which is why re-applying
  # an UNCHANGED value renews nothing. Renewal is a CHANGED duration.
  #
  # 8760h is the live value, so this commit is a zero-diff no-op — which is the
  # point: it moves the number out of a comment and into the render, where
  # checks.<system>.access-service-token-duration can hold it.
  resource.cloudflare_zero_trust_access_service_token.mcp_public = {
    account_id = accountId;
    name = "mcp-public-gateway";
    duration = "8760h";
  };
```

**Measured, not predicted:** the render diff is exactly one JSON key. Today `{"account_id":"…","name":"mcp-public-gateway"}`; after, that plus `"duration":"8760h"`. Nothing else in the 26-registration render moves.

## 1c. The build-time check

**Where:** `modules/parts/terranix.nix`'s `perSystem` — **not** `checks.nix`. `flake.lib` exports only `cfTunnelConfig` and `mcpPublicConfig` (`terranix.nix:1293-1298`); all six renderers are in scope only inside that file.

**The enabler:** terranix's `terranixConfiguration` returns the JSON derivation with `passthru = { config; _meta; }`, so `(mcpPublicConfig {…}).config` is the **rendered Terraform attrset at eval time, no build**.

```nix
  # terranix.nix's perSystem head is `{ config, system, ... }:` — use pkgsFor.
      # ---- Every Access service token NAMES its own expiry -------------------
      # `duration` is Optional+Computed with Default("8760h"), so omitting it does
      # not mean "no expiry" — it means a one-year expiry nobody wrote down. For
      # mcp-public that credential is the portal's only one.
      #
      # WHAT THIS CANNOT DO, so the limit is a choice and not an oversight: eval
      # is pure, so it cannot know today's date or read expires_at. It asserts
      # only that the window is a DECLARED number and that the number is legal.
      # Days-LEFT is the plan-time banner in mkMcpPublicTofu.
      checks.access-service-token-duration =
        let
          pkgs = pkgsFor system;
          inherit (nixpkgs) lib;
          # `.config` is terranix's passthru — the Terraform attrset at EVAL time,
          # no build. Only strings escape, so it costs no aarch64-linux build. The
          # two GCP stacks are absent: a Cloudflare resource cannot appear there.
          renders = [
            { stack = "cf-tunnel"; cfg = (cfTunnelConfig { inherit system hostedSites; }).config; }
            { stack = "mcp-public"; cfg = (mcpPublicConfig { inherit system; publicServers = publicMcpServers; }).config; }
            { stack = "cf-zones"; cfg = (cfZonesConfig { inherit system; }).config; }
            { stack = "cf-access-org"; cfg = (cfAccessOrgConfig { inherit system; }).config; }
          ];

          # Deliberately STRICTER than Go's time.ParseDuration: no leading sign,
          # no bare `0`, no leading-dot form. A token lifetime is never negative
          # and never zero, so the narrowing is the point. The provider ships NO
          # validator on this attribute, so a typo is otherwise a 400 at apply.
          wellFormed =
            d: d == "forever" || builtins.match "([0-9]+(\\.[0-9]+)?(ns|us|µs|ms|s|m|h))+" d != null;

          tokens = lib.concatMap (
            r:
            lib.mapAttrsToList (name: v: {
              inherit name;
              inherit (r) stack;
              duration = v.duration or null;
            }) (r.cfg.resource.cloudflare_zero_trust_access_service_token or { })
          ) renders;

          problems =
            map (t: "${t.stack}: ${t.name} declares no duration, so it inherits the provider default 8760h") (
              lib.filter (t: t.duration == null) tokens
            )
            ++ map (t: "${t.stack}: ${t.name} duration ${t.duration} is neither a Go duration nor forever") (
              lib.filter (t: t.duration != null && !(wellFormed t.duration)) tokens
            );
        in
        pkgs.runCommand "access-service-token-duration" { } (
          if problems == [ ] then
            ''
              echo "access service tokens: ${toString (builtins.length tokens)} rendered, every one with an explicit duration" > $out
            ''
          else
            ''
              echo "access-service-token-duration: a service token leaves its expiry to the provider." >&2
              ${lib.concatMapStringsSep "\n" (x: ''echo "  ${x}" >&2'') problems}
              echo "" >&2
              echo "  The default is 8760h and it is SILENT. For mcp-public that credential" >&2
              echo "  is the portal's only one, so its lapse takes every published server" >&2
              echo "  dark at once, with no partial failure first." >&2
              echo "  Declare duration in infra/cloudflare/<stack>.nix. Changing it later is" >&2
              echo "  an in-place update, not a replacement, so it cannot rotate the secret." >&2
              exit 1
            ''
        );
```

**House idiom matched exactly:** `echo "  ${x}" >&2` (two spaces, no prefix) and `> $out` unquoted — that is `checks.nix:249-259`. No backticks in any advice line (`nixpi-security-posture`'s rule).

**Same PR, fix the comment this falsifies:** `modules/parts/checks.nix:8-13` says "**all four files** merge into one per-system attrset". Make it **five**, naming `modules/parts/terranix.nix` and why — four of the six renderers are never exported through `flake.lib`.

## 1d. The plan-time banner — inside `mkMcpPublicTofu`, after `tofu init` (`terranix.nix:1038`)

```bash
        # ---- The expiry as a NUMBER, not a comment ---------------------------
        # `expires_at` is Computed on the token (schema.go:96-99), so STATE holds
        # the date and reading it costs no API call. Fresh by construction: the
        # date only moves on an apply. Printed on every plan and apply because
        # this stack's one credential is also its single point of total failure.
        if token_state=$(tofu show -json 2>/dev/null) && [ -n "$token_state" ]; then
          expires=$(printf '%s' "$token_state" | ${pkgs.jq}/bin/jq -r '
            ( .values.root_module.resources // [] )
            | map(select(.type == "cloudflare_zero_trust_access_service_token"))
            | .[0].values.expires_at // ""
          ')
          exp_s=""
          [ -n "$expires" ] && exp_s=$(date -u -d "$expires" +%s 2>/dev/null || true)
          if [ -n "$exp_s" ]; then
            left=$(( (exp_s - $(date -u +%s)) / 86400 ))
            echo "service token mcp-public-gateway expires $expires ($left days left)" >&2
            if [ "$left" -lt 60 ]; then
              echo "WARNING: under 60 days. When it lapses EVERY published server goes dark" >&2
              echo "  at once, with no partial failure first. Renew by CHANGING duration and" >&2
              echo "  applying — re-applying the same value is a no-op and renews nothing." >&2
            fi
          else
            # NOT the same as a healthy window. This repo already took the
            # fail-OPEN wound once (terranix.nix:476-479): an empty result that
            # reads identically to "nothing is wrong".
            echo "service token expiry: state unreadable, expiry UNKNOWN" >&2
            echo "  Not a healthy window — this run simply could not read it." >&2
          fi
        fi
```

`coreutils` is already in `mkMcpPublicTofu`'s `runtimeInputs`, so `date -u -d` is GNU date on darwin. `jq` is not — reach it as `${pkgs.jq}/bin/jq`, matching `terranix.nix:1046`. Advisory only: **never `exit 1`**.

## 1e. What NOT to build

- **Do not** bolt an expiry probe onto `packages/launchd-doctor.nix`. Its header scopes it to launchd units on the running machine (`:1-23`, `:35` "NO NIX-TIME THREADING").
- **Do not** write a poller. Cloudflare ships `cloudflare_notification_policy` with `alert_type = "expiring_service_token_alert"` — the off-the-shelf answer (`upstream-first`). **But it is apply-gated AND scope-gated:** it needs Account Settings Read/Write + Notifications Read/Write, which `cf:cloudflare.com:mcp-public` does not document (`terranix.nix:1014-1020`). If you add it without widening the token, **the apply FAILS and changes nothing** — a new resource has nothing to refresh, the 403 lands on the create, the 26 registrations stay live. Cost is a wasted run, **not an outage**. Defer it to its own PR.

**Apply needed for 1b?** Only to make the render authoritative. It plans as **0 to change**. **PR title:** `apps, checks, packages, docs`

---

# 2. Per-server policy tiers — yes, with one loud caveat

## 2a. Read this before writing any code

**LOUD — the silent lockout.** `portalApp` (`mcp-public.nix:278-296`) hands `policies = [{ id = operatorPolicyId; precedence = 1; }]` to **every** published server. Repointing that id is an **in-place attribute update at an unchanged resource address**. The drop guard compares **addresses** (`terranix.nix:1128`, `comm -23`); the floor guard counts only `..._mcp_server`. **Neither fires.** A mis-scoped tier policy locks you out of **all 26 portal apps in one irreversible apply, with zero refusals.**

**LOUD — never mutate `mcp_allow_operator`.** `infra/cloudflare/nixpi-tunnel.nix:377` pins it by literal id `b3bd8c38-e231-4203-ba6b-69fe16e498b3` from a **different tofu stack**. Narrowing it narrows **who can SSH the Pi**, in the same apply, with no plan line naming the Pi. Tiering **ADDS** policies.

**What tiering actually buys** (and what it does not):

| Buys | Does not buy |
|---|---|
| A second Workspace human gets the read-only shelf without a shell on this Mac | **Any isolation today** — one account on the domain, so all tiers admit the same person |
| Structure before the second human exists | **Containment** — the direct URL + service token reaches all 26 |
| — | **MFA / purpose justification / temporary auth** — not enforced on portal-authorized mcp apps |

`docs/mcp-public-exposure-design.md` §10 already settled this: *"absence is no longer a boundary … Narrowing `publicMcpServers` is the only lever that restores absence."* A per-server policy narrows **who**, not **what is reachable**. §8 records that you were shown the four-tier split and **chose to publish all 26** — this is adding identity constraints to an unchanged roster, not re-litigating that.

## 2b. Tier data — new `let` bindings after `cfId` (`mcp-public.nix:134`)

```nix
  # ============================ THE TIERS ===================================
  # WHO may see WHICH server through the portal. Only IDENTITY selectors work
  # here: Cloudflare enforces Emails, Groups, Country and Device Posture on a
  # portal-authorized mcp app and silently drops independent MFA, purpose
  # justification and temporary authentication. There is NO selector for WHICH
  # CLIENT connected, so a tier separates PEOPLE — never claude.ai from grok.com.
  #
  # Tiers are EXCLUSIVE, not cumulative. Access evaluates an app's policies in
  # ASCENDING precedence and the first matching Allow or Block ends evaluation —
  # so a wider allow behind a tighter one still admits everyone the tighter one
  # rejected. One tier per server.
  tierPolicyIds = {
    operator = "\${cloudflare_zero_trust_access_policy.mcp_tier_operator.id}";
    trusted = "\${cloudflare_zero_trust_access_policy.mcp_tier_trusted.id}";
    domain = "\${cloudflare_zero_trust_access_policy.mcp_tier_domain.id}";
  };

  # Membership is checked HERE, not at the call site, so a gateway name and an
  # external Worker's `tier` field fail the same actionable way.
  policyIdFor =
    tier:
    tierPolicyIds.${tier} or (throw ''
      mcp-public: unknown tier "${tier}".
      Valid tiers: ${builtins.concatStringsSep ", " (builtins.attrNames tierPolicyIds)}.
    '');

  # One row per published server. NO default and no `or` fallback: a server added
  # to fleet.publicMcpServers must be classified by what it can DO, or the throw
  # fails the render here rather than widening its audience at Cloudflare.
  serverTier = {
    # operator — executes code, drives this Mac, or holds prod/personal data.
    desktop-commander = "operator";  # arbitrary shell + filesystem
    macos-automator = "operator";    # AppleScript/JXA, incl. `do shell script`
    chrome-devtools = "operator";    # evaluate_script in the logged-in browser
    mobile-mcp = "operator";         # drives a real device over adb
    postgres = "operator";           # general SQL executor
    wordpress = "operator";          # prod site admin: users, app passwords
    wordpress-adapter = "operator";  # same prod site, via the abilities API
    github = "operator";             # PAT-backed: push, merge, delete, create
    cloudflare = "operator";         # account API — can edit the gate you read
    "gmail-aloshyakasoto_gmail_com" = "operator";
    "gmail-ismail_kattakath_com" = "operator";
    "gmail-ismailkattakath_gmail_com" = "operator";
    "gmail-izzy_silvercreek_ai" = "operator";

    # trusted — side effects that OUTLIVE the request: money, or bytes on disk.
    apify = "trusted";   # actor runs are billed
    memory = "trusted";  # writes the shared knowledge graph
    arxiv = "trusted";   # downloads papers + persists topic watches

    # domain — read-only lookups, no credentials, no persisted side effect.
    context7 = "domain";
    cloudflare-docs = "domain";
    duckduckgo = "domain";
    fetch = "domain";
    json-yaml-toml = "domain";
    mcp-jq = "domain";
    mcpfinder = "domain";
    nixos = "domain";
    sequential-thinking = "domain";
    terraform = "domain";
  };

  tierOf =
    name:
    serverTier.${name} or (throw ''
      mcp-public: published server "${name}" has no tier.
      Classify it in `serverTier` by what it can DO — operator (shell/prod/
      personal data), trusted (spend or persisted state), or domain (read-only).
      Publishing it untiered would hand it the widest audience by accident.
    '');
```

Roster coverage verified: all 26 keys set-diff clean against `modules/parts/identity.nix:222` in **both** directions.

## 2c. The reverse guard — tier → roster

`tierOf` catches roster→tier only. A name deleted from `fleet.publicMcpServers` leaves a stale row forever. `mcp-published-parity` checks **both** directions (`checks.nix:238-246`) precisely because the one-directional predecessor missed the opposite. Match it:

```nix
  publishedIds = map (p: p.id) published;
  strayTiers = builtins.filter (k: !(builtins.elem k publishedIds)) (builtins.attrNames serverTier);
  # Forced on every portal app, so a stale row fails the render rather than
  # sitting here describing a server Cloudflare no longer knows about.
  tierGuard =
    x:
    if strayTiers == [ ] then
      x
    else
      throw "mcp-public: serverTier classifies unpublished server(s): ${toString strayTiers}";
```

## 2d. `published` gains one field — replaces `mcp-public.nix:175-187`

```nix
  published =
    map (n: {
      key = "srv_${srvKey n}";
      id = n;
      regId = cfId n;
      policyId = policyIdFor (tierOf n);
      description = "Published from the macos MCP gateway (fleet.publicMcpServers).";
    }) publicServers
    ++ map (e: {
      key = "srv_${srvKey e.name}";
      id = e.name;
      regId = cfId e.name;
      # An unclassified external origin defaults to the TIGHTEST tier, not the
      # widest: a new Worker nobody has classified should fail closed.
      policyId = policyIdFor (e.tier or "operator");
      description = e.description or "Cloudflare Worker route under the gateway hostname.";
    }) externalServers;
```

Also update `mcp-public.nix:86`: `# Each entry: { name; description ? ""; tier ? "operator"; }`

## 2e. `portalApp` reads the data — replaces `mcp-public.nix:290-295`

```nix
  portalApp =
    p:
    tierGuard (
      accessAppCommon
      // {
        # … unchanged name/type/destinations …
        # ONE policy per app. `precedence` is required and starts at 1, exactly
        # as the origin app and the portal front door already declare it.
        policies = [
          {
            id = p.policyId;
            precedence = 1;
          }
        ];
      }
    );
```

Keep it a single policy, not a list + `genList` — every tier yields exactly one id, and list plumbing would document behaviour the code never exercises.

## 2f. The three NEW policies — beside `mcp-public.nix:363`, never an edit

```nix
  # DO NOT DELETE, and do not narrow: infra/cloudflare/nixpi-tunnel.nix:377 pins
  # this object by LITERAL ID from a DIFFERENT tofu stack for the Pi's SSH gate.
  # Since the tier split it has only ONE referent in this file (`portal`), which
  # makes it LOOK unused here. It is not.
  # (existing resource.cloudflare_zero_trust_access_policy.mcp_allow_operator)

  # ---- The tier policies — NEW objects, never an edit above -------------------
  resource.cloudflare_zero_trust_access_policy.mcp_tier_domain = {
    account_id = accountId;
    name = "mcp-tier-domain";
    decision = "allow";
    # Identical rule to mcp_allow_operator today — deliberately a SECOND object
    # with the same body, so widening the read-only shelf later cannot reach SSH.
    include = [ { email_domain.domain = domainName; } ];
  };

  resource.cloudflare_zero_trust_access_policy.mcp_tier_trusted = {
    account_id = accountId;
    name = "mcp-tier-trusted";
    decision = "allow";
    # An explicit roster, not a group object: `include` is a SET whose rules are
    # OR'd, so N emails need no cloudflare_zero_trust_access_group — which would
    # also need an Access: Organizations/IdPs/Groups scope this stack's token is
    # not documented to carry.
    include = [ { email.email = googleAccount; } ];
  };

  resource.cloudflare_zero_trust_access_policy.mcp_tier_operator = {
    account_id = accountId;
    name = "mcp-tier-operator";
    decision = "allow";
    # `email`, not `email_domain`: the whole point is that a second human on the
    # Workspace domain must not also get a shell on this Mac.
    include = [ { email.email = googleAccount; } ];
  };
```

**Thread `googleAccount`:** add `googleAccount,` to `mcp-public.nix`'s function head (REQUIRED, no `? default` — the file states why at `:62-66`), and add `googleAccount` to the `inherit` inside `mcpPublicConfig`'s `_module.args` (`terranix.nix:109-116`). It is already a `let` binding at `terranix.nix:32`.

## 2g. Also fix, same PR

- `infra/cloudflare/nixpi-tunnel.nix:337` still reads `; not yet applied` — **stale**; `mcp-public.nix:359` says `LIVE since 2026-09-22`. Delete the clause.
- `infra/cloudflare/mcp-public.nix:219-221` still says *"there is NO plan app; `tofu plan -out=policy.tfplan` by hand"* — **stale** since #592. `mcp-public-plan` exists at `terranix.nix:1318-1323`.

## 2h. What an apply does

| Action | Objects |
|---|---|
| **CREATE** | 3 × `cloudflare_zero_trust_access_policy` |
| **UPDATE IN PLACE** | 26 × `..._access_application.portal_*` — only `policies` changes |
| **UNCHANGED** | `mcp_allow_operator`, `origin_gateway`, `portal`, all 26 registrations, the portal attachment, the tunnel, DNS, the service token |
| **DIFFERENT STACK, UNTOUCHED** | `nixpi_ssh` and its literal policy id |

**STOP the apply if:** any `-/+ replace` on a `portal_*` app (that server disappears from every portal until the create lands); any diff at all on `mcp_allow_operator`; any `+ create` for `mcp_allow_operator` (the import was skipped — an apply mints a second policy and orphans `nixpi_ssh`).

**`decision = "bypass"` is forbidden here.** Bypass and Service Auth are evaluated **before** Block and Allow, whatever the numbers — a bypass policy on a portal app silently defeats every tier.

**PR title:** `apps, docs`

---

# 3. Device posture — DO NOT DO THIS

**Ground truth, measured, not assumed:**

| Probe | Result |
|---|---|
| `cloudflare-warp` in any Homebrew cask list | **absent** |
| Cloudflare WARP / One app in `/Applications` | **absent** |
| `warp-cli` on PATH | **absent** (only `/opt/homebrew/bin/cloudflared`) |
| `/Library/Managed Preferences` | **empty** — no MDM |
| `cloudflare_zero_trust_device_posture_rule` anywhere in `infra/` | **absent** |
| `access-org.nix:124` | `allow_authenticate_via_warp = false` — the org **disallows** it |

**The two posture families that need no client are both structurally dead here:**

| Agentless posture type | Why it cannot work |
|---|---|
| Microsoft Entra ID Conditional Access | No Entra tenant. The sole IdP is Google Workspace (`mcp-public.nix:194`). |
| Mutual TLS | mTLS is **FQDN-bound**; an mcp-type app declares **no domain**. And the clients are `claude.ai`, `claude.com`, `grok.com` — vendor cloud connectors that cannot present a client certificate. |

**The exact reason to skip, not a preference:** `require[].device_posture.integration_uid` must name something an **enrolled** device satisfies. With zero enrolled devices, every such `require` evaluates **false**. Shipping it does not harden the tier — it takes it **offline**. That is a fail-closed outage dressed as a control.

**And the bootstrap is circular:** Cloudflare — *"Device posture checks are not supported in device enrollment policies. The Cloudflare One Client can only perform posture checks after the device is enrolled."*

**Enrolling would cost:** a resident network-extension client that must stay running and routing (WARP down ⇒ posture unknown ⇒ **every sensitive server dark**), a new `type = "warp"` enrollment app, and an edit to `access-org.nix` — the stack whose header says editing it is how you take out `ssh` and both deploy legs. For **one Mac, one operator, one domain**, posture re-asserts something identity already asserts. **Not proportionate.**

**Recorded for the next person, NOT shipped** (so nobody re-derives it): `require = [ { device_posture.integration_uid = "…"; } ]` — name grounded at v5.25.0. **UNVERIFIED:** the attribute is documented as *"the ID of a device posture **integration**"* while a rule id is what you would naturally wire. **What would verify it:** a real plan against an enrolled fleet — which does not exist.

---

# 4. Ephemeral worker — the boundary is not proven. Measure first.

## 4a. Auth mechanics — grounded

| Where | `decision` | `include` |
|---|---|---|
| Portal app (`mcp_portal`) | `"non_identity"` | `service_token.token_id` |
| **Each** per-server app (`mcp`) | `"non_identity"` | `service_token.token_id` |

`non_identity` is Terraform's spelling of the dashboard's **Service Auth**. `allow` is wrong — Access would redirect the token to the IdP. This exact pair already applies in this repo at `mcp-public.nix:375-384`. `on_behalf = false` is already set for every server (`:522`) — the third required condition, **zero churn**.

## 4b. The scoping question — the answer, and its limit

**An identity policy cannot admit a non-identity caller.** So without an explicit Service Auth policy on each per-server app, the worker connects and enumerates **zero tools**. Fail-closed. Good.

**LOUD — but that is a DISCOVERY filter, not a proven authorization boundary.** Cloudflare's documented sentence is: *"If a linked MCP server does not have a Service Auth policy matching the token, that server is **hidden from the bot's tool list**."* The docs say **nothing** about what happens when a service-token session issues a `tools/call` naming a tool on a hidden server. And this repo is **public** — `modules/parts/identity.nix:222` lists all 26 names, so "the attacker doesn't know the tool name" is not available as an assumption.

**Acceptance test that must run before anyone relies on the tier:**
1. `tools/list` with the worker headers must equal the tier **exactly**.
2. Issue a `tools/call` naming a tool on a **non-tier** server (a `gmail-*` tool is the sharp case). Record whether it 403s.

If (2) succeeds, the tier is **obscurity**, and the correct answer is the second-hostname argument already recorded at `mcp-public.nix:25-33`.

## 4c. The plumbing — SIX edits, and one fails SILENTLY

**LOUD — `modules/parts/terranix.nix:1036` is the edit that fails silently.** It reads `cp ${mcpPublicConfig { inherit system publicServers; }} config.tf.json` and is the **only** call site inside `mkMcpPublicTofu`. Miss it and `mcpPublicConfig`'s own `workerServers ? [ ]` default wins: the render succeeds, the plan reads `2 to add, 0 to change`, the apply succeeds, and the worker enumerates **nothing**.

| # | File:line | Edit |
|---|---|---|
| 1 | `identity.nix:222` | add the `mcpWorkerServers = [ … ]` let binding |
| 2 | `identity.nix:457` | add `mcpWorkerServers` to `config.fleet = { inherit … }` — `fleet` is freeform `lazyAttrsOf raw`; a let binding alone creates **nothing** |
| 3 | `terranix.nix:21` | add `mcpWorkerServers` to `inherit (config.fleet)` — without it the identifier at the apps is **undefined** and the flake does not evaluate |
| 4 | `terranix.nix:94` | `workerServers ? [ ],` in `mcpPublicConfig`'s head |
| 5 | `terranix.nix:112` | add `workerServers` to the `_module.args` inherit |
| 6 | `terranix.nix:981` **and `:1036`** | `workerServers ? [ ],` in `mkMcpPublicTofu`'s **closed** pattern (no ellipsis — an unexpected arg is an eval error), **and forward it in the `cp`** |

Then the apps at `:1318`/`:1329`. `mcp-public-destroy` (`:1401`) correctly keeps the `[ ]` default.

**Guard so #6 cannot be forgotten silently** — same shape and placement as the existing render/state guard:

```bash
        want=${toString (builtins.length workerServers)}
        if [ "$want" -gt 0 ]; then
          got=$(${pkgs.jq}/bin/jq '[.resource.cloudflare_zero_trust_access_application
                 | .. | objects | select(has("policies")) | .policies[]
                 | select(.id | test("mcp_ci_worker"))] | length' config.tf.json)
          # 1 portal app + one per tier server. Fewer means the tier never reached
          # the renderer — the silent no-op, not a narrower scope.
          if [ "$got" -lt $((want + 1)) ]; then
            echo "REFUSING: $want tier server(s) declared but only $got worker policy refs rendered." >&2
            echo "  workerServers did not reach mcpPublicConfig (modules/parts/terranix.nix:1036)." >&2
            exit 1
          fi
        fi
```

## 4d. The tier — **`github` is OUT**

```nix
  # The CI worker tier — what an ephemeral runner may reach through the portal.
  # A STRICT SUBSET of publicMcpServers, excluded BY CLASS: nothing that holds a
  # credential and nothing that drives a machine. A leaked CI secret reaches the
  # portal plus every server here with NO identity, NO MFA, NO DCR check and no
  # browser — this list is the only bound.
  #
  # `github` is deliberately absent even though it looks like a dev tool: the
  # portal's github server carries push / merge / delete / create-repository, and
  # CI already has a strictly better credential — the ~1h App token the runner
  # lanes mint from the agenix gh-app-* keys, which is per-job and scoped. Use
  # `gh` in the job, not the portal.
  mcpWorkerServers = [
    "context7"
    "duckduckgo"
    "fetch"
    "json-yaml-toml"
    "mcp-jq"
    "nixos"
    "sequential-thinking"
    "terraform"
  ];
```

## 4e. The token and its policy — beside `mcp-public.nix:384`

```nix
  # ---- The CI worker's own service token -------------------------------------
  # SEPARATE from `mcp_public`, which is the PORTAL's credential for dialling the
  # origin. Two hops, two holders: rotating the worker's token must not dark the
  # portal, and a leaked worker token must not become a portal credential.
  #
  # `duration` is DECLARED, unlike mcp_public was — an ephemeral-CI credential is
  # the one place a SHORT window is cheap, because nothing holds it at rest.
  resource.cloudflare_zero_trust_access_service_token.mcp_ci_worker = {
    account_id = accountId;
    name = "mcp-ci-worker";
    duration = "2160h"; # 90 days — rotate with CI's own secret rotation
  };

  # Service Auth, in the provider's spelling. `non_identity` IS the dashboard's
  # "Service Auth", and it is the only action a service-token rule works with: an
  # `allow` policy sends the caller to the IdP instead.
  resource.cloudflare_zero_trust_access_policy.mcp_ci_worker = {
    account_id = accountId;
    name = "mcp-ci-worker: service token only";
    decision = "non_identity";
    include = [
      { service_token.token_id = "\${cloudflare_zero_trust_access_service_token.mcp_ci_worker.id}"; }
    ];
  };
```

Attach at `precedence = 2` beside the existing entry on the portal app (`:478-483`) and on each tier server's app. **Never swap the existing id wholesale** — see §2a.

**Credential extraction: TWO apps, not one.** `mcp-public-token` exists to print **only** a raw value so it pipes into `secret set` (`terranix.nix:1248-1251`). A two-line id-then-secret stream forces the value onto a terminal — which also trips Rule 1c of the PreToolUse guard. Mirror it as `mcp-ci-worker-id` and `mcp-ci-worker-secret`, each ending in a bare `tofu output -raw <name>` with `tofu init` on stderr.

## 4f. Clients — this path is CLI/headless only

| Client | Sends `CF-Access-*`? | Consequence |
|---|---|---|
| Claude Code | **Yes** (`--header`, `headers`) | usable directly |
| `mcp-remote` shim | **Yes** (`--header`) | the bridge for anything else |
| curl / headless agent | **Yes** | usable |
| **Claude Desktop** | **No, and it is this repo's fault** | `claude-desktop.nix:96-110` already routes everything through mcp-remote, but `render`'s `exclude` at `:124-133` **drops `headers`** and `toStdioShim` emits no `--header`. Declaring headers evaluates, activates, and sends **nothing**. |
| **grok.com** | **No** — URL only, no header field | permanently OAuth/DCR only |

**For CI, pass `--header` at runtime** rather than baking `${VAR}` into a checked-in file: Claude Code refuses to expand *credential-like* variable names in remote-server headers, and a silently-empty header looks identical to a wrong token. Whether `CF_ACCESS_CLIENT_SECRET` trips that heuristic is **UNVERIFIED**.

## 4g. DCR — grounded

**A service-token caller bypasses the browser OAuth flow entirely.** The worker does **not** need to be in `allowed_uris` (`mcp-public.nix:466-473`), and that allowlist is **not** a second line of defence for it. The only two gates are the portal Service Auth policy and the per-server Service Auth policy. **There is no third.**

**PR title (if it ships):** `apps, packages, docs`

---

# Conventions and gates the combined change must satisfy

## Will any guard refuse it?

| Guard | `terranix.nix` | Fires on this work? |
|---|---|---|
| unreadable state | `:1062-1071` | no |
| empty render over live state (`MCP_PUBLIC_ALLOW_EMPTY`) | `:1074-1083` | no — counts only `..._mcp_server` |
| empty state, full render (`MCP_PUBLIC_ALLOW_CREATE`) | `:1115-1126` | no |
| **drop delta** (`MCP_PUBLIC_ALLOW_DROPS`) | `:1128-1139` | **only if you RENAME an existing Nix attribute.** Add beside; never rename. |

**Never set `MCP_PUBLIC_ALLOW_DROPS=1` to get past a rename** — it deletes the live object.

**A `-/+ replace` is invisible to all four.** Address present on both sides. **Read the plan.**

## Other gates

- **`mcp-published-parity` holds.** It asserts **bidirectional set equality of name strings** only (`checks.nix:234-259`) and reads no policy. A tiered-but-still-published server keeps parity green. **Rule: keep `config.fleet.publicMcpServers` a flat `listOf str`.** Tier data goes in a **separate** `fleet.*` attribute — free, since `options.fleet` is freeform `lazyAttrsOf raw`. **Never** a fifth field in `identityArgs` (closed submodule).
- **ast-grep — none of the six fire.** The two layer rules are glob-scoped to `modules/features/**` and `modules/shared/**`. *Would* fire if a tier list went into `modules/shared/**` reaching `../parts/` or `../../infra/` — **don't**.
- **`claude-md-budget`:** CLAUDE.md is **35,676 bytes**, cap 40,000 — **4,324 bytes headroom**. Explain tiering in `docs/mcp-public-exposure-design.md`, one line in CLAUDE.md.
- **`docs-indexed`:** any new `docs/*.md` must be grep-able in CLAUDE.md or `docs/repo-map.md`.
- **ADR-005 §9:** declare new policies as **CREATEs** in the existing stack. **Never re-import** what is already in state. **§4:** no seventh stack.

## The commands — and the ones you must never propose

```bash
git add -- '*.nix'                            # flakes ignore untracked files
nix fmt
nix flake check --all-systems --no-build      # evaluate BOTH systems
nix flake check                               # THE SUITE
nix run .#mcp-public-plan                     # operator only; read it
```

| May propose | **Never** |
|---|---|
| `mcp-public-plan`, `mcp-public-sync`, `nix flake check`, `gh pr create` | any `*-destroy` app, `tofu destroy`, `tofu state rm`, `wrangler`, a `developers.cloudflare.com` fetch from Bash, `secret reveal`, `agenix -d`, `gh pr merge`, `git push --force`, reading `~/.local/state/nix-config-mcp-public/**` |

**`mcp-public-apply` is the operator's call alone.** `tofu apply` has **no rollback** — unlike `deploy --targets .#nixpi`, there is no magicRollback here.

## PR titles — per `.claude/rules/pr-title.md`

| PR | Title |
|---|---|
| 0 — provider pin | `apps` |
| 1 — duration + check + banner + doc index | `apps, checks, packages, docs` |
| 2 — tiers + two stale comments | `apps, docs` |
| 4 — worker (if it ships) | `apps, packages, docs` |

**Open every one as a DRAFT, off `main`.** Auto-merge lands a PR the moment checks go green — #567 lost five commits to that race.

---

# Loud lines, collected

- **NEVER edit or rename `cloudflare_zero_trust_access_policy.mcp_allow_operator`.** `nixpi-tunnel.nix:377` pins it by literal id from another stack — you would move the Pi's SSH gate.
- **Swapping `operatorPolicyId` wholesale in `portalApp` locks you out of all 26 portal apps in one apply, and NO wrapper guard fires.**
- **A `-/+ replace` on any `portal_*` app** = that server vanishes from every portal until the create lands. No rollback.
- **`MCP_PUBLIC_ALLOW_DROPS=1` to silence a rename DELETES the live object.**
- **Never attach a `geo` or `device_posture` require to `mcp_public_service_token` or `origin_gateway`** — the caller there is Cloudflare's own edge, not your laptop. It fails all 26 at once.
- **Do not ship a `device_posture` require anywhere.** Zero enrolled devices ⇒ it evaluates false ⇒ the tier goes offline.
- **Do not add `source = "cloudflare/cloudflare"` to `mcp-public.nix`** — that is state surgery (`tofu state replace-provider`) on the encrypted GCS state of the stack owning all 26, with no flake app lane.
- **The `geo.country_code` option is a travel lockout** on exactly the servers you would use to fix it. Leave it out.