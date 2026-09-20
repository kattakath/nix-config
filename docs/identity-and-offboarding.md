# Identity and offboarding — one lever

**The Google Workspace account on the org domain is the canonical identity.** Everything else
signs in through it or is bound to it. Phase 3 of ADR-004 writes that down as a `googleAccount`
binding in `modules/parts/identity.nix`; this page is the property it encodes.

## The single lever

**Suspend the Workspace account → every derived login is gone at once.** No checklist.

| What is revoked | Why it follows without a second action |
|---|---|
| GitHub (org and personal) | signs in through Google |
| FlakeHub / Determinate | authenticates with the Google identity — and with it the native Linux builder entitlement |
| Cloudflare Access — MCP portal, published servers, `nixpi` SSH | the only IdP is the Workspace domain (`Kattakath Google Workspace`, type `google-apps`), measured 2026-09-20 |
| Secrets recovery (Secret Manager → Keychain, ADR-004) | IAM on the GCP project is granted to the Workspace identity |

**One caveat, measured, not assumed:** the reusable Access policy `mcp-allow-operator` today
allows by **email**, not by domain (ADR-004 §8.4). Suspension still revokes — the email cannot
authenticate through a suspended account — but *adding* a second human needs a policy edit until
that policy is re-declared as `email_domain`. The proposed terranix diff is in ADR-004 §8.4; it
is not applied.

## Privilege tiers

| Tier | Who / what | How it authenticates | Granted by |
|---|---|---|---|
| **Universal baseline** | every human | the Google account, everywhere (SSO / OIDC) | existing on the domain |
| **Privileged exception — AWS** | specific people, per product | AWS IAM Identity Center (SSO), profiles in a *local* `~/.aws/config`, sessions minted at `aws sso login` | per person, per product; revoked in Identity Center, not by Workspace suspension alone |
| **CI deploys** | GitHub Actions | **OIDC** (`id-token: write`) — FlakeHub publishing, and any future cloud deploy | the workflow, never a human's credential |

The middle tier is why the secrets backend is GCP and not AWS (ADR-004 §2.2): recovery must be
available to the baseline human, and only Google is universal here.

## What offboarding does NOT need

- **No Terraform change** for Cloudflare, once §8.4's policy is domain-based. Today: one edit.
- **No CI credential rotation.** CI never held a human's token.
- **No config edit before suspension.** Access is gone the moment the account is.

## Then, at leisure (hygiene, not access)

- Delete their `users.users.<name>` / `home-manager.users.<name>` — a pure deletion, marked
  `OPERATOR-ONLY` where it is operator-specific.
- Rotate anything they held **locally** that was shared. A `mode = "reference"` item needs
  nothing: the reference is useless without the identity that just went away.
- If they held the AWS exception, remove the Identity Center assignment as well.
