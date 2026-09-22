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

`ws-domain-admin` holds **domain-wide delegation**: it can act as any user in the domain,
without that user's consent, for the OAuth scopes it is granted.

That grant lives in the **Workspace Admin console** (Security → API controls → Domain-wide
delegation), keyed by the service account's OAuth **client id** and a scope list. No Terraform
provider can read or write it — not the archived Workspace one, and certainly not
`hashicorp/google`, which manages the account but never its delegation.

`infra/gcp/foundation.nix` therefore declares **the account only**, and says so at the
resource. That split is the honest one: the identity is code, the authority is a console screen.

### Its key is the exception to the single lever

`ws-domain-admin` has a **USER_MANAGED** key (created 2026-09-07), stored in the login Keychain
as `gcp:kattakath-family:ws-domain-admin-key` — not loose on disk, which is the one piece of
good news here.

**A domain-wide-delegated service-account key does NOT stop working when the human Workspace
account is suspended.** The single lever in
[`identity-and-offboarding.md`](identity-and-offboarding.md) revokes everything that
*authenticates as the human*. This key does not: it authenticates as itself and then impersonates
whoever it likes.

**Anecdote, because the asymmetry is easy to miss:** suspending the account is changing the locks
on the building. The DWD key is a master key you cut for a contractor once and never got back —
the new locks do not know about it. *(Where it breaks down: you can revoke this one instantly,
which is not true of a real lost key — see the offboarding step below.)*

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

**Scopes cannot be verified from a CLI.** Admin console → Security → API controls → Domain-wide
delegation, and read the scope list against what §2 says it is for. If the list is wider than
"Admin SDK domain + site verification", something granted itself more.

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
   Until this runs, that key still acts as any user in the domain.
3. **Remove the domain-wide delegation entry** in the Admin console, so a future key cannot
   inherit the authority.
4. `secret rm gcp:kattakath-family:ws-domain-admin-key`.
5. Then the "at leisure" hygiene in the identity doc.

**Steps 2 and 3 are the whole reason this page exists.** They are invisible from the repo, they
survive the single lever, and nothing else names them.

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
