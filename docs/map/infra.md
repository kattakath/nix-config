Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `infra/` — terranix (Nix → OpenTofu/Terraform JSON)

**Five stacks, and the split is deliberate: a stack is a blast radius, not a category.**

| Stack | State | Breaking it takes down |
|---|---|---|
| `cf-tunnel` | GCS `cf-tunnel/` | the Pi |
| `cf-zones` | GCS `cf-zones/` | **mail** |
| `cf-access-org` | GCS `cf-access-org/` | **every Access app at once** |
| `gcp-budget` | GCS `gcp-budget/` | the spend alert |
| `gcp-foundation` | **local** (still encrypted) | the bucket the others live in |

> **A SIXTH stack, `mcp-public`, was DESTROYED AND DELETED on 2026-10-02.** It owned the
> published MCP gateway's Cloudflare side — tunnel, portal, per-server registrations, Access
> apps, service token. Two destroy runs removed **65 objects**; the API then reported **0** MCP
> server registrations (was 27), **0** portals (was 1), **0** `mcp-public` tunnel, **0**
> mcp/upstream Access applications, and `https://mcp.kattakath.com/mcp` answers **403**. Its
> state object, the `mcp-public-{plan,apply,destroy,sync,token}` apps, the
> `packages.mcp-worker-probe` helper and `fleet.publicMcpServers`/`publicMcpPort` went with it.
> **Do not re-add a stack to publish MCP** — [`claude.md`](claude.md) § MCP after the gateway
> says what replaced it, and
> § The `mcp-public` teardown below records the one object that refused to die and why that
> refusal was correct.

**Run every one of these inside `nix develop`.** Not a style preference — `CLOUDSDK_CONFIG`
scopes `gcloud`, but it does **not** scope Terraform: the Go auth library ignores it and reads
the well-known ADC path instead, so only the devShell's `GOOGLE_APPLICATION_CREDENTIALS`
(`modules/parts/devshell.nix`) points tofu at this repo's credentials. Measured 2026-09-22: a
bare `nix run .#cf-access-org-plan` failed at `Initializing the backend` with
`izzy@silvercreek.ai does not have storage.objects.list access` — a correct `gcloud` account and
a tofu authenticated as a **different Workspace tenant** entirely. The 403 was the lucky
outcome; the shape to fear is an ambient credential that *does* have access and writes to the
wrong place silently. Canonical invocation:

```bash
nix develop -c bash -c 'secret exec CLOUDFLARE_API_TOKEN=cf:cloudflare.com:api -- nix run .#<app>'
```

State is the shared, versioned bucket `kattakath-tofu-state` (named once, as
`fleet.gcpStateBucket`), **encrypted** with a passphrase
read from the login Keychain at run time via `TF_ENCRYPTION` (ADR-005 phase 1 —
[`iac-coverage-adr.md`](../iac-coverage-adr.md)). `cf-tunnel`'s state holds a secret in plaintext
inside the payload (the connector token), which is why encryption is not optional — it was two
until `mcp-public` was deleted. `gcp-foundation` keeps local state
because it *declares* that bucket — **and it is encrypted too.** The invariant is ENCRYPTION,
not remoteness: **every** stack sources the same `tofuRemoteStatePrelude`
(`modules/parts/terranix.nix`), so the passphrase can never be wired on all but one and
forgotten on the last. "Local" here says where the file sits, never that it is plaintext.
(That property is why the retired `mcp-public` state was safe to abandon: its payload carried a
connector token and an Access service-token secret, and the GCS object holding them was
encrypted at rest with the same Keychain passphrase.)

### `infra/cloudflare/zones.nix` + `infra/cloudflare/kattakath-dns.nix`

`kattakath.com`'s 22 DNS records — the module renders, the sibling file is the data. Only this
zone is declared, and the line is drawn by **ownership, not secrecy**: DNS is a public query, so
publishing the operator's own zone discloses nothing `dig` does not, while the other six zones
belong to businesses that are not only his.

Records owned by another stack are deliberately absent — today that is `nixpi` alone. (`upstream`
and `mcp` used to be here as absences too: `upstream` belonged to the retired `mcp-public` stack
and `mcp` was created by Cloudflare with the portal. Both are **destroyed**, not merely
unmanaged, so a future render must not grow them back in order to "fix" a missing record.)
Importing one twice is how a plan grows a destroy.

Its guard is shaped for its own failure mode — a **record-count floor** — because the way this
stack hurts you is a shrunken render silently deleting mail, not a bad tunnel. Applied via
`cf-zones-apply`; `cf-zones-plan` is read-only. There is no `cf-zones-destroy`.

### `infra/cloudflare/access-org.nix`

The Zero Trust **organisation** — one resource, `cloudflare_zero_trust_organization`, and its
own stack because it sits *above* the other Cloudflare ones rather than beside them:
`auth_domain` is the sign-in host for **every** Access application in the account, so a bad
apply takes out nixpi's SSH gate along with anything else gated there. (Until 2026-10-02 the
"anything else" was the MCP portal, which is what made this stack's blast radius legible in the
first place; with the portal gone, nixpi's SSH app is the ONLY thing left behind this
`auth_domain` — which makes a bad apply here *more* consequential, not less, because there is no
longer a second victim to notice it by.) One resource is not an argument for folding it into a
neighbour; the rule keys on consequence, not line count.

**What it is for:** the login page's branding (`login_design` — logo, background, header,
footer). **Its original audience is gone**: it was the *only* surface in the MCP connector flow
carrying the operator's mark, and there is no MCP connector flow any more. What remains is the
sign-in page an operator sees when Access challenges them for `ssh` to the Pi, which is a real if
much smaller surface. The measurement that justified it is kept because it is about Claude and
Cloudflare, not about this fleet: Claude renders a generic globe for every custom connector —
`serverInfo.icons` exists in MCP spec 2025-11-25 but Claude does not read it
([anthropics/claude-ai-mcp#152](https://github.com/anthropics/claude-ai-mcp/issues/152)), and
Cloudflare's portal object has no icon field either (both measured 2026-09-22). The logo is the
**wordmark** (512x132), not the square icon, because the login header is wide — and it is a
URL Cloudflare fetches, not an upload, so the asset is hosted rather than committed here.

**Two traps, both guarded in the wrapper:**

1. **Every attribute is optional** in the pinned provider (5.25.0, verified via
   `tofu providers schema -json`). There is no "manage only `login_design`" mode, so a render
   declaring just the branding is not a safe subset — it describes an organisation whose other
   fields are unset. The module therefore **mirrors** the live object, and the rule for editing
   it inverts the usual one: *do not remove a field you are not using.* An omission is an
   instruction to blank it. The wrapper refuses outright if the render has lost `auth_domain`.
2. **Import, never create.** There is one organisation per account, created 2026-07-03. The
   wrapper refuses an apply against state that does not already track it and prints the import
   command, because a create here is a clobber.

Data lives in `config.fleet.accessOrg` (`modules/parts/identity.nix`). Applied via
`cf-access-org-apply`; `cf-access-org-plan` is read-only. There is **no** destroy app — there is
no API to delete an organisation, so a destroy would merely blank one.

### `infra/gcp/foundation.nix`

Enabled APIs, the automation service account, its IAM bindings, and the OpenTofu state bucket.

**Its state is LOCAL but not plaintext.** It cannot live in the bucket it declares, so it sits
`0600` under `$XDG_STATE_HOME/nix-config-gcp-foundation` — and it still runs
`tofuRemoteStatePrelude`, so the same Keychain passphrase encrypts it via `TF_ENCRYPTION`. Lose
`tofu:state:passphrase` and this state is unreadable exactly like the other five.

**Runs as the OPERATOR, not the service account it declares.** Running it as that account would
need `serviceUsageAdmin` + `iam.serviceAccountAdmin` + `projectIamAdmin` — the power to re-grant
itself anything. The privileged bootstrap stays with the human; the narrow stacks use the
least-privileged identity it creates, by **impersonation**, with no key file anywhere.

It also declares `ws-domain-admin`, the Workspace-facing account — the account only. Its
authority would live in the Admin console, which no provider reaches:
[`workspace-runbook.md`](../workspace-runbook.md).

### `infra/gcp/budget.nix`

A **5 CAD** spend budget. **An alert, not a cap** — Google offers no hard spending limit on a
billing account, and the currency must match the account's own or the API rejects it as a bare
`400`. Applied via `gcp-budget-apply`.

### `infra/cloudflare/nixpi-tunnel.nix`

Declares `nixpi`'s **remotely-managed** Cloudflare Tunnel itself:

- a `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`),
- its ingress (`cloudflare_zero_trust_tunnel_cloudflared_config`: SSH → `ssh://localhost:22`,
  one rule per `hostedSites` entry → the local Caddy at `http://localhost:80`, plus the
  mandatory catch-all `http_status:404`),
- one proxied `cloudflare_dns_record` CNAME per site → `<tunnel-id>.cfargotunnel.com`,
- the connector **token** surfaced as a sensitive `output` (via the
  `cloudflare_zero_trust_tunnel_cloudflared_token` data source),
- **the edge's TLS floor, DECLARED rather than clicked** — a `cloudflare_zone_setting` per
  setting (`ssl = strict`, `min_tls_version = 1.2`, `always_use_https`, HSTS) for the SSH
  host's zone **and** every hosted site's zone,
- **the SSH Access gate** — `cloudflare_zero_trust_access_application.nixpi_ssh`. Declaring it
  is not tidiness: that object **vanished once, on 2026-08-20**, and took `ssh` plus both deploy
  legs down with it. Declared, a rebuild restores the gate instead of a dashboard click.

Zones with no terranix module here (aloshy.ai, etuper.com, izzykatt.ca, silvercreek.ai) are
still configured out-of-band, so none of the above applies to them.

A pure function of its `hostedSites`/`domainName`/`accountId`/`zoneId` module args (same
shape/default as `mkNixos`); `cf-tunnel-apply`/`cf-tunnel-destroy` pass the fleet's real
`hostedSites` (`config.fleet.hostedSites`), while their `*-destroy` counterparts deliberately
keep the `[ ]` default so tearing the real stack down still needs the explicit
`CF_TUNNEL_ALLOW_SITE_FREE=1` override (`modules/parts/terranix.nix`). Applied/destroyed via the
`cf-tunnel-apply`/`cf-tunnel-destroy`
flake apps (an API credential must be exported first — never in Nix); `cf-tunnel-apply` prints
the token to stdout to be stored via `nix run .#nixpi-vault-token` into
`secrets/cloudflared-token.age`, never written to git/store in plaintext.

**`cf-tunnel-import` — run it before the next apply, once.** #737 DECLARED
`cloudflare_zero_trust_access_policy.nixpi_ssh_operator` (the SSH gate's allow rule, previously
owned by the deleted `mcp-public` stack) but never imported the live object, so state does not
track it. A `cf-tunnel-plan` therefore reads `+ create`, and an apply would mint a SECOND policy
on the gate. The import is an APP and not a documented `tofu import` line for the reason
`mkCfAccessOrgImport` already gives: by hand it means reconstructing `TF_ENCRYPTION` in an
interactive shell, which puts the state passphrase into the operator's shell history — the one
secret-handling regression every wrapper in `modules/parts/terranix.nix` exists to avoid. It
imports and stops: no plan, no apply, nothing that can write to Cloudflare.

After it, `cf-tunnel-plan` must read either "No changes" or an in-place update on the POLICY
ONLY whose every line is `exclude`/`require`/`session_duration` going `[] -> null`. **STOP** on a
`+ create` on the policy (the import did not take), on `-/+ replace` or `- destroy` (that object
is referenced by `nixpi_ssh` — deleting it locks the Pi out of its Access-gated ingress), or on
any change to `include` (who may SSH would change). The full condition list lives at the
declaration site, `infra/cloudflare/nixpi-tunnel.nix`.

### The `mcp-public` teardown — DELETED 2026-10-02, and the one object that refused to die

`infra/cloudflare/mcp-public.nix` is **gone**, with its five `mcp-public-*` apps, its
`packages.mcp-worker-probe` helper, its GCS state object and its
`fleet.publicMcpServers`/`publicMcpPort` inputs. This section is kept because the teardown
measured things worth not re-learning, not because any of it is still operable. **There is no
`mcp-public-plan` to run.**

**What it was.** The Cloudflare half of the published MCP gateway; the other half was the single
`mcp-proxy` in `modules/shared/mcp.nix`, whose whole roster was `config.fleet.publicMcpServers`.
Live 2026-09-12 → 2026-10-02. From ONE list it rendered a `cloudflared` tunnel + connector for
the Mac, ingress to `:8097`, the proxied CNAME, one Access application over the origin hostname,
one `non_identity` service-token policy, one portal registration per published server, one
`mcp`-type Access application per server, and the portal's own `mcp_portal` application carrying
the DCR allowlist.

**What the teardown measured**, via the Cloudflare API after two destroy runs — **65 objects
destroyed**:

| | Before | After |
|---|---|---|
| MCP server registrations | 27 | **0** |
| portals | 1 | **0** |
| `mcp-public` tunnel | 1 | **0** |
| mcp/upstream Access applications | several | **0** |
| `https://mcp.kattakath.com/mcp` | the one connector every client dialled | **403** |

**The instructive part: ONE object survived, and Cloudflare was right to refuse.** The Access
policy `mcp_allow_operator` would not delete —
`409 code 12132 "policy is being used by at least one app"` — because it is **shared with the
`nixpi.kattakath.com` SSH Access app**. That refusal **protected the Pi's only Access-gated
ingress**: the same class of object that vanished on 2026-08-20 and took `ssh` plus both deploy
legs with it. Read it that way round. It is not cleanup debt and must not be "finished off" — a
destroy that had succeeded here would have been the 2026-08-20 outage, caused deliberately.
The general lesson, which outlives this stack: a shared Access policy means **one stack's destroy
can reach into another stack's blast radius**, and the API-level reference count is the only
thing standing in the way. ADR-005 §4's "a stack is a blast radius" holds for *resources a stack
declares*, not for objects it merely shares.

**Design facts that outlived the stack**, because they are about Cloudflare's model rather than
this fleet's wiring:

- **Exactly two hostnames, and they did not grow per server.** `mcp.<domain>` was the portal
  clients talked to — the only address handed out. `upstream.<domain>` was the origin, dialled
  only by the portal with a service token; a browser got 403 because the policy was
  `non_identity` with no login path. Remote Workers published as Worker **routes** under that
  same origin (`/servers/<name>/*`), matched at the edge before the tunnel, so a Worker and a
  laptop-local process shared one hostname and one `aud`.
- **Three objects were required to publish one server, and missing any of them failed
  SILENTLY**: the registration, its attachment to the portal, and its `mcp`-type Access
  application. A registration could sit at `status = "ready"` with its tools discovered and still
  be invisible to every client — and testing at the origin could not detect it, because the
  origin answered `200` throughout. The verification rule that came out of this is general:
  **verify at the surface clients actually use, not at the one that is easiest to curl.**
- The **drop guards** (`MCP_PUBLIC_ALLOW_EMPTY=1`, `MCP_PUBLIC_ALLOW_DROPS=1`) did their job to
  the end — the final teardown needed them explicitly, which is exactly the "do you really mean
  to destroy this" checkpoint they were built to be. `cf-tunnel`'s equivalent
  (`CF_TUNNEL_ALLOW_SITE_FREE=1`) is unchanged and still guards the Pi.

Design-doc history, now wholly retrospective:
[`mcp-public-exposure-design.md`](../mcp-public-exposure-design.md),
[`mcp-portal-hardening-plan.md`](../mcp-portal-hardening-plan.md), and
[`mcp-gateway.md`](../mcp-gateway.md) for the roster side.

## Binary cache (Cachix)

The public `kattakath` cache is consumed by every host and the devcontainer — but by **two
different mechanisms**, which is why its module is NixOS-only: `modules/nixos/nix-cache.nix`
(`nix.settings`, in `mkNixos`'s module list) for the NixOS hosts, and
`determinateNix.customSettings` in `mkDarwin` for the Mac, where Determinate owns
`/etc/nix/nix.conf` and `nix.*` is unavailable. The URL/key literal is single-sourced for both
from `flake.nix` via `cachixUrl`/`cachixKey`. Read is public — only the substituter
URL + public key, **NO token on any consumer**. The write credential `CACHIX_AUTH_TOKEN` lives
in exactly two places: a **GitHub Actions secret** (used by `cachix/cachix-action` in
`nix-ci.yml`, `build-devcontainer.yml`, and `build-installers.yml` to push build closures) and
— since 2026-08-21 — the operator's **login Keychain** (registered via `secret set`,
loader-exported like every personal token) for ad-hoc local `cachix push kattakath <paths>`;
never in Nix or git, and consumers still substitute tokenless (read stays public). Note the
token does NOT influence builds or substitution — Nix sandboxes scrub the environment, so it is
only ever consumed by the `cachix` CLI at push time.

