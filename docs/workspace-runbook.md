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

### Its key: a liability today, an exception to the single lever tomorrow

`ws-domain-admin` has a **USER_MANAGED** key (created 2026-09-07), stored in the login Keychain
as `gcp:kattakath-family:ws-domain-admin-key` — not loose on disk, which is the standard pattern
here and the right call.

**Today it grants nothing in Workspace**, because no delegation is registered (above). It is an
unused long-lived credential attached to an account with no Workspace authority and no GCP
project roles. That makes it pure liability rather than pure risk: nothing depends on it, and it
can only ever become more powerful, never less.

**The moment a delegation IS registered, it becomes the exception to the single lever.** The
lever in [`identity-and-offboarding.md`](identity-and-offboarding.md) revokes everything that
authenticates *as the human*. A delegated key does not: it authenticates as itself and then
impersonates whoever it likes.

**Anecdote, because the asymmetry is easy to miss:** suspending the account changes the locks on
the building. A delegated key is a master key cut for a contractor — the new locks do not know
about it. *(Where it breaks down today: no such key has been cut yet. The blank is signed but not
filled in.)*

**Recommendation: delete the key** unless something is verified to use it. An unused credential
on a domain-admin-shaped account is the cheapest thing in this fleet to remove and the most
expensive to explain later.

---

## 3. Verify

Run inside `nix develop`, so gcloud and ADC are scoped to this repo.

```bash
# The account exists and is not disabled
gcloud iam service-accounts describe ws-domain-admin@kattakath-family.iam.gserviceaccount.com

# KEYS. A second USER_MANAGED key appearing here is an incident, not drift.
gcloud iam service-accounts keys list \
  --iam-account=ws-domain-admin@kattakath-family.iam.gserviceaccount.com

# The key material is in the Keychain, and `fp` proves identity without printing it
secret fp gcp:kattakath-family:ws-domain-admin-key

# The Workspace-facing APIs are the three expected ones
gcloud services list --enabled --project=kattakath-family | grep -E 'admin|drive|gmail'

# Cloudflare still trusts exactly one IdP
#   (needs CLOUDFLARE_API_TOKEN; see infra/cloudflare/)
```

**Scopes cannot be verified from a CLI** — there is no public API for the delegation table.
Admin console → Security → API controls → Domain-wide delegation.

**Expected state, as of 2026-09-22: the API clients table is EMPTY.** Any row appearing there is
a change worth explaining, and a row for `ws-domain-admin` means the latent risk in §2 just went
live — at which point §4 steps 2 and 3 become mandatory rather than precautionary.

---

## 4. Offboarding — the ordered version

[`identity-and-offboarding.md`](identity-and-offboarding.md) is right that suspension revokes
every *derived human login* with no checklist. This is the part that suspension does not cover:

1. **Suspend the Workspace account.** Everything in that document's table goes at once.
2. **Delete the `ws-domain-admin` USER_MANAGED key** — the step the single lever cannot do:
   ```bash
   gcloud iam service-accounts keys delete <KEY_ID> \
     --iam-account=ws-domain-admin@kattakath-family.iam.gserviceaccount.com
   ```
3. **Check the Admin console delegation table** and remove any row for that client, so a future
   key cannot inherit the authority.
4. `secret rm gcp:kattakath-family:ws-domain-admin-key`.
5. Then the "at leisure" hygiene in the identity doc.

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
