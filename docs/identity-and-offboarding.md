# Identity and offboarding — one lever

**The Google Workspace account on the org domain is the canonical identity.** Everything else
signs in through it or is bound to it. It is the `googleAccount` binding in
`modules/parts/identity.nix` (`config.fleet.googleAccount`, also `flake.identity.googleAccount`;
spelled `${loginName}@${domainName}` because that is how Workspace mints it); this page is the
property it encodes.

## The single lever

**Suspend the Workspace account → every derived login is gone at once.** No checklist.

| What is revoked | Why it follows without a second action |
|---|---|
| GitHub (org and personal) | signs in through Google |
| FlakeHub / Determinate | authenticates with the Google identity — and with it the native Linux builder entitlement |
| Cloudflare Access — MCP portal, published servers, `nixpi` SSH | the only IdP is the Workspace domain (`Kattakath Google Workspace`, type `google-apps`), measured 2026-09-20 |
| Secrets recovery (Secret Manager → Keychain, ADR-004) | IAM on the GCP project is granted to the Workspace identity |

**~~One caveat~~ — RESOLVED 2026-09-22.** `mcp-allow-operator` now allows by **`email_domain`**
(`kattakath.com`), applied through terranix after importing the live object so no duplicate
policy was minted. Adding a second human is a Workspace action, not a policy edit. It gates 28
applications, `nixpi.kattakath.com` among them, so that one change widened SSH to the Pi from one
mailbox to the domain — intended, and worth knowing. The apply also dropped the policy's
`session_duration = "24h"`, which the resource does not declare.

**The caveat that replaces it, and it is bigger.** Suspension revokes every login that
authenticates *as the human*. It does **not** revoke a domain-wide-delegated service-account
key, which authenticates as itself and then impersonates whoever it likes. One exists:
`ws-domain-admin`, key in the login Keychain. Deleting it is a manual step that no amount of
suspending accounts performs — [`workspace-runbook.md`](workspace-runbook.md) §4 is the ordered
procedure, and §2 is why it cannot be code.

## Privilege tiers

| Tier | Who / what | How it authenticates | Granted by |
|---|---|---|---|
| **Universal baseline** | every human | the Google account, everywhere (SSO / OIDC) | existing on the domain |
| **Privileged exception — AWS** | specific people, per product | AWS IAM Identity Center (SSO), profiles in a *local* `~/.aws/config` (the `cloud-cli` capsule ships only `config.example`), sessions minted at `aws sso login` | per person, per product; revoked in Identity Center, not by Workspace suspension alone |
| **CI deploys** | GitHub Actions | **OIDC** (`id-token: write`) — FlakeHub publishing, and any future cloud deploy | the workflow, never a human's credential |

The middle tier is why the secrets backend is GCP and not AWS (ADR-004 §2.2): recovery must be
available to the baseline human, and only Google is universal here.

## What offboarding does NOT need

- **No Terraform change** for Cloudflare — the policy is domain-based as of 2026-09-22.
- **No CI credential rotation.** CI never held a human's token.
- **No config edit before suspension.** Access is gone the moment the account is.

## What offboarding DOES need, beyond the lever

Exactly two things, both in [`workspace-runbook.md`](workspace-runbook.md) §4: delete the
`ws-domain-admin` USER_MANAGED key, and remove its domain-wide delegation entry in the Admin
console. Until both are done, that identity still acts as any user in the domain.

## Then, at leisure (hygiene, not access)

- Delete their `users.users.<name>` / `home-manager.users.<name>` — a pure deletion, marked
  `OPERATOR-ONLY` where it is operator-specific.
- Rotate anything they held **locally** that was shared. A `mode = "reference"` item needs
  nothing: the reference is useless without the identity that just went away.
- If they held the AWS exception, remove the Identity Center assignment as well.
