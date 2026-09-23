# Google Workspace — the runbook, because it cannot be code

**Status:** ADR-005 phase 4. Current as of **2026-09-22**, measured against the live tenant.

Every other surface in this fleet is declarative. This one is not, and that is a **decision**
rather than a gap — ADR-005 §3.3. The reason is one line:

> `hashicorp/terraform-provider-googleworkspace` was **archived 2025-06-30**. No releases, no
> issue triage, no maintenance.

A community fork exists. It is not adopted, because Workspace is the **single offboarding
lever** every other login derives from ([`identity-and-offboarding.md`](identity-and-offboarding.md)),
and an unmaintained provider in that path fails at exactly the moment it is needed.

So Workspace is operated by hand, and this page is what "by hand" is allowed to mean: a written
inventory, a verification command per item, and the two things that must never be done.

---

## 1. What exists, measured

| Object | Value | Where it is configured |
|---|---|---|
| Organisation | `kattakath.com`, id `26567817213` | Workspace / Cloud Console |
| Canonical identity | `config.fleet.googleAccount` | **declared** (`modules/parts/identity.nix`) |
| Cloudflare Access IdP | `Kattakath Google Workspace`, type `google-apps` — the **only** IdP | Cloudflare, declared |
| GCP project | `kattakath-family`, billing `016854-91C33C-F9E522` (CAD) | **declared** (ADR-005 phase 3) |
| Admin-SDK automation identity | `ws-domain-admin@kattakath-family.iam.gserviceaccount.com` | account **declared**; its power is not — see §2 |
| Terraform automation identity | `tofu-fleet@kattakath-family.iam.gserviceaccount.com` | **declared**, impersonated, no key |
| Workspace-facing APIs | `admin`, `drive`, `gmail` | **declared** (`infra/gcp/foundation.nix`) |
| Gmail MCP accounts | 4, each its own process | **declared** (`hosts/macos.nix`) |

Everything marked *declared* re-plans clean. Everything else is in this document because there
is nowhere else to put it.

---

## 2. The part no provider can reach

`ws-domain-admin` is NAMED for domain-wide delegation — the authority to act as any user in the
domain, without that user's consent, for a granted scope list.

**It does not have it. Verified 2026-09-22 in the Admin console: the API clients table under
Security → API controls → Domain-wide delegation is EMPTY.** No client is registered, so no
scope is delegated to anything.

That gap between the name and the reality is the finding. The account's own `description` field
reads "Domain-wide delegation for Admin SDK domain + site verification", which describes an
intent that was never completed — and which reads, to anyone auditing, as authority that exists.

Such a grant — if one were ever made — lives in the **Workspace Admin console** (Security → API
controls → Domain-wide delegation), keyed by the service account's OAuth **client id** and a
scope list. No Terraform provider can read or write it: not the archived Workspace one, and not
`hashicorp/google`, which manages the account but never its delegation. That is why the table
can only be checked by eye, and why this page records what it looked like.

`infra/gcp/foundation.nix` therefore declares **the account only**, and says so at the
resource. That split is the honest one: the identity is code, the authority is a console screen.

### Its key — DELETED 2026-09-22

`ws-domain-admin` carried a **USER_MANAGED** key (created 2026-09-07, id `22ada9c0…`) with its
private material in the login Keychain. It granted nothing: no delegation was registered, and the
account holds no GCP project role. An unused long-lived credential on a domain-admin-shaped
account is the cheapest thing in this fleet to remove and the most expensive to explain later, so
it was removed — both halves:

```
gcloud iam service-accounts keys delete 22ada9c0… --iam-account=ws-domain-admin@…
secret rm gcp:kattakath-family:ws-domain-admin-key
```

Checked first, and this is the check to repeat before deleting any key: no env binding, no
launchd agent, no reference anywhere in this repo outside its own documentation.

**One key remains and must stay: the `SYSTEM_MANAGED` one.** That is Google's own, rotated by
Google, and it is what makes *impersonation* possible. Deleting it is not a hardening step.

**Why this mattered even though nothing was delegated.** The lever in
[`identity-and-offboarding.md`](identity-and-offboarding.md) revokes everything that
authenticates *as the human*. A delegated key would not: it authenticates as itself and then
impersonates whoever it likes. No delegation existed — but a key sitting ready on an account
named for delegation is one console click away from that being true, and the click leaves no
trace in this repo.

**Anecdote:** suspending the account changes the locks on the building. A delegated key is a
master key cut for a contractor — the new locks do not know about it. *(Where it broke down here:
the key was cut but no door had been fitted to it. Destroying it while that was still true cost
nothing.)*

---

## 3. Verify

Run inside `nix develop`, so gcloud and ADC are scoped to this repo.

```bash
# The account exists and is not disabled
gcloud iam service-accounts describe ws-domain-admin@kattakath-family.iam.gserviceaccount.com

# KEYS. Expected: exactly ONE, and SYSTEM_MANAGED. Any USER_MANAGED key here is
# an incident, not drift — the last one was deleted 2026-09-22.
gcloud iam service-accounts keys list \
  --iam-account=ws-domain-admin@kattakath-family.iam.gserviceaccount.com

# The Workspace-facing APIs are the three expected ones
gcloud services list --enabled --project=kattakath-family | grep -E 'admin|drive|gmail'

# Cloudflare still trusts exactly one IdP
#   (needs CLOUDFLARE_API_TOKEN; see infra/cloudflare/)
```

**Scopes cannot be verified from a CLI** — there is no public API for the delegation table.
Admin console → Security → API controls → Domain-wide delegation.

**Sign in as `ismail@kattakath.com` to do it, and as nothing else.** It is the only account in
this fleet with Admin console access on `kattakath.com`. The Mac holds four Google logins (the
four `gmail-*` MCP servers), and the other three cannot open that screen at all — notably
`izzy@silvercreek.ai`, which *is* a full Workspace account with GCP access, but on a **different
tenant**. "Log in to Google and check" is therefore not a well-formed instruction here; three
of the four answers are a permission error.

That tenant boundary is real and was measured rather than assumed: running a terranix app under
`izzy@silvercreek.ai`'s ADC on 2026-09-22 failed with
`does not have storage.objects.list access` on `kattakath-tofu-state` — a different Workspace,
correctly walled off from this project. The consequence worth keeping: **suspending
`ismail@kattakath.com` does not touch `izzy@silvercreek.ai`**, because the single lever in
[`identity-and-offboarding.md`](identity-and-offboarding.md) is scoped to *this* domain. That is
correct, not a gap — the silvercreek identity is a different business's to revoke — but it means
the lever is one-per-tenant, and this fleet's Mac is signed into two.

**Expected state, as of 2026-09-22: the API clients table is EMPTY.** Any row appearing there is
a change worth explaining, and a row for `ws-domain-admin` means the latent risk in §2 just went
live — at which point §4 steps 2 and 3 become mandatory rather than precautionary.

---

## 4. Offboarding — the ordered version

[`identity-and-offboarding.md`](identity-and-offboarding.md) is right that suspension revokes
every *derived human login* with no checklist. This is the part that suspension does not cover:

1. **Suspend the Workspace account.** Everything in that document's table goes at once.
2. **Delete any USER_MANAGED key** on `ws-domain-admin` — the step the single lever cannot do.
   There is none as of 2026-09-22; confirm rather than assume:
   ```bash
   gcloud iam service-accounts keys delete <KEY_ID> \
     --iam-account=ws-domain-admin@kattakath-family.iam.gserviceaccount.com
   ```
3. **Check the Admin console delegation table** and remove any row for that client, so a future
   key cannot inherit the authority.
4. Then the "at leisure" hygiene in the identity doc.

**Steps 2 and 3 are the whole reason this page exists.** They are invisible from the repo and
they survive the single lever. With the delegation table empty they are currently cheap
insurance; if a row ever appears there, they become the difference between offboarding and the
appearance of it.

---

## 5. Never

- **Never create a second USER_MANAGED key** on a domain-wide-delegated account. The org policy
  `constraints/iam.managed.disableServiceAccountApiKeyCreation` blocks *API keys*, not service
  account keys — it will not stop you.
- **Never put a service-account key in `/nix/store`.** The store is world-readable. Keychain, or
  it does not exist.
- **Never widen the delegation scopes to "make something work".** A scope added for a one-off is
  permanent authority over every mailbox in the domain.
- **Never adopt the archived Workspace provider to automate this.** See the status line, and
  ADR-005 §3.3.

---

## 6. When this page is allowed to become code

ADR-005 §7's trigger: **Google ships a first-party Workspace provider, or the community fork
gains a second maintainer.** At that point §2 and §4 are the migration checklist, and this page
becomes the record of what was true before.
