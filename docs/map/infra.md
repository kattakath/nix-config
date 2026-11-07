Part of the [repo map](../repo-map.md) — the full fleet architecture.

## `infra/` — terranix (Nix → OpenTofu/Terraform JSON)

**A stack is a blast radius, not a category, and the split is deliberate.**

| Stack | State | Credential | Breaking it takes down |
|---|---|---|---|
| `cf-tunnel` | GCS `cf-tunnel/` | `CLOUDFLARE_API_TOKEN` | **the Pi**: tunnel, ingress, CNAMEs, every zone's TLS floor, the `nixpi_ssh` Access app |
| `cf-zones` | GCS `cf-zones/` | `CLOUDFLARE_API_TOKEN` | **mail**, silently until a message bounces |
| `cf-access-org` | GCS `cf-access-org/` | `CLOUDFLARE_API_TOKEN` | **every Access app at once** (`auth_domain`) |
| `gcp-budget` | GCS `gcp-budget/` | ADC | the spend ALERT (an alert, never a cap) |
| `gcp-foundation` | **local** (still encrypted) | ADC | the bucket the others live in |
| `hc-checks` | GCS `hc-checks/` | `HEALTHCHECKSIO_API_KEY` | the dead-man's-switch ALARMS; a quiet one reads as a healthy host |
| `grafana` | GCS `grafana/` | `GRAFANA_AUTH` + `GRAFANA_SM_ACCESS_TOKEN` | Grafana alerting, datasources, dashboard, probe (ADR-011). A dropped datasource takes its key with it |
| `github` | GCS `github/` | `GITHUB_TOKEN` | fleet repos' branch protection, merge queue, CI variables. A Tier A `QUEUE_ENABLED` without its queue rule merges untested; never declare an Actions SECRET (state) |

The stack set itself is `nix eval .#apps.<system> --apply builtins.attrNames` (every stack has
a `*-plan`). **Credentials:** a token is an env var `secret exec` fills from the Keychain; a `*-plan` run
without it prints the exact `nix develop -c secret exec …` line. ADC is
`gcloud auth application-default login`, scoped by `nix develop`.

> **A FORMER stack, `mcp-public`, was DESTROYED AND DELETED on 2026-10-02** (65 objects, its
> apps and state with it). **Do not re-add a stack to publish MCP** — [`claude-code.md`](claude-code.md)
> § MCP after the gateway says what replaced it; § The `mcp-public` teardown below has the record.

Every provider VERSION is pinned exactly in one file, `infra/provider-pins.nix`; each stack keeps
its own `source` address (changing a source is a `tofu state replace-provider`, not a bump). Its
header records why those are registry downloads and not nixpkgs `opentofu.withPlugins`.

**Run every one of these inside `nix develop`.** Not a style preference — `CLOUDSDK_CONFIG`
scopes `gcloud`, but it does **not** scope Terraform: the Go auth library ignores it and reads
the well-known ADC path instead, so only the devShell's `GOOGLE_APPLICATION_CREDENTIALS`
(`modules/parts/devshell.nix`) points tofu at this repo's credentials. Measured 2026-09-22: a
bare `nix run .#cf-access-org-plan` failed at `Initializing the backend` with
`<client-tenant account> does not have storage.objects.list access` — a correct `gcloud` account and
a tofu authenticated as a **different Workspace tenant** entirely. The 403 was the lucky
outcome; the shape to fear is an ambient credential that *does* have access and writes to the
wrong place silently. Canonical invocation:

```bash
nix develop -c bash -c 'secret exec CLOUDFLARE_API_TOKEN=<handle> -- nix run .#<app>'
```

`<handle>` is a Cloudflare Keychain entry from the token table in
[`secrets-and-keychain.md`](../secrets-and-keychain.md) § Cloudflare tokens. A stack's own file
may name the handle it needs, with the reason — `nixpi-tunnel.nix`'s "ADOPTION IS IMPORT-FIRST"
block does.

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

### `infra/cloudflare/zones.nix` + `infra/cloudflare/kattakath-dns.nix` + `infra/cloudflare/kattakath-redirects.nix`

`kattakath.com`'s DNS records and its redirect ruleset — the module renders; `kattakath-dns.nix`
and `kattakath-redirects.nix` are the data. Only this
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

The Zero Trust **organisation** and the account-level Zero Trust objects (the file is the list), and its
own stack because it sits *above* the other Cloudflare ones rather than beside them:
`auth_domain` is the sign-in host for **every** Access application in the account, so a bad
apply takes out nixpi's SSH gate along with anything else gated there. (Until 2026-10-02 the
"anything else" was the MCP portal, which is what made this stack's blast radius legible in the
first place.) Few resources is not an argument for folding it into a
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
`cf-access-org-apply`; `cf-access-org-plan` is read-only. There is **no** destroy app: it would
blank the organisation and DELETE the IdP (`prevent_destroy` refuses that).

### `infra/gcp/foundation.nix`

The GCP project's declared objects (the file is the list; what stays out is ADR-005 §10).

**Its state is LOCAL but not plaintext.** It cannot live in the bucket it declares, so it sits
`0600` under `$XDG_STATE_HOME/nix-config-gcp-foundation` — and it still runs
`tofuRemoteStatePrelude`, so the same Keychain passphrase encrypts it via `TF_ENCRYPTION`. Lose
`tofu:state:passphrase` and this state is unreadable exactly like every other stack's.

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

### `infra/healthchecks/checks.nix`

One `healthchecksio_check` per entry of **`config.fleet.heartbeats`**
(`modules/parts/heartbeats.nix`) — the fleet's heartbeat (dead man's switch) registry, pure data,
no secrets. The attribute name is the healthchecks.io **slug**; a host pings
`<baseUrl>/<project ping key>/<slug>` (`local.heartbeat` + `local.serviceHeartbeat`,
[`modules-nixos.md`](modules-nixos.md)), so the check created here and the URL a pinger builds
cannot drift. An entry sets exactly one of `schedule` (cron) or `period` (seconds) plus a
mandatory `grace`; the render refuses both/neither, a bad slug, or more than the free plan's 20.

- **Provider:** `kristofferahl/healthchecksio`, **pinned exactly** in `infra/provider-pins.nix`
  (OpenTofu registry; nixpkgs does not package it). `tofu validate` was run against the real provider schema.
- **Auth:** `HEALTHCHECKSIO_API_KEY` (the provider's own env var — not `HEALTHCHECKS_API_KEY`),
  the project's read-write **API key**, via
  `nix develop -c secret exec HEALTHCHECKSIO_API_KEY=hc:healthchecks.io:api -- nix run .#hc-checks-plan`.
  Hosts hold a different credential, the **ping key**, which can only ping.
- **Apps:** `hc-checks-plan` (read-only, run first) and `hc-checks-apply`. No import (the first
  apply creates the checks) and no destroy. Guards: refuses a render that **drops** a check state
  holds (`HC_CHECKS_ALLOW_DROPS=1`), an apply against **empty state** (`HC_CHECKS_ALLOW_CREATE=1`,
  the legitimate first-apply override) and `-auto-approve`.
- **Alert channels:** empty `fleet.heartbeatChannels` (the default) means the project's email
  integration, found by a guarded data lookup that fails the plan if it is missing; set the
  option only to override with explicit UUIDs.
- **Every check is wired (2026-11-02).** `nixpi-serving` ← nixpi's `service-heartbeat` (runitor);
  each `nix-config-*` CI slug ← its workflow's "Heartbeat ping" step, on **scheduled** runs only
  (#1032; the `pingers` map, slug + cron parity, and a `cron:` workflow with no pinger are all
  gated by `checks.<system>.heartbeat-workflow-parity`); `evidence-discover` ← the agentic-jobseek cloud
  routine, a different repo; `nix-config-terranix-drift` ← the Mac's daily drift agent (below);
  `nix-config-doctors-weekly` ← `doctor-report weekly`, run by the operator's weekly Claude Desktop
  task (ADR-013 § 6; the task is app state, so it reads `new` until its first run). A
  FUTURE entry still needs its pinger: a never-pinged check stays `new` and **never alerts**
  (`Check.get_status`).
- State object `hc-checks/` in the shared encrypted bucket; the working dir is
  `$XDG_STATE_HOME/nix-config-hc-checks`.

### Saved plans (ADR-012 § 5 step 5)

`<stack>-plan -- -out=<file>`, then `<stack>-apply -- <file>`. The plan is **bound** to its
stack and render, the **wrapper** asks for `yes` (tofu would not), and the file is encrypted:
`savedPlanRun` in `modules/parts/terranix.nix`.

### Drift detection — `terranix-drift` (ADR-012 § 5 step 1)

A daily user agent on `macos` (`nix-terranix-drift`, 06:00 local, on wake if asleep) runs
**every** `*-plan` app with `-detailed-exitcode -lock=false`. The stack list is derived from the
flake's `*-plan` packages, so a new stack is covered with no edit. Its Keychain credential comes
from the wrapper's `passthru.terranixDriftEnv`.

- **Exit classes:** 0 clean, 2 drift, anything else **error** (an auth failure is an error).
- **Alert:** healthchecks.io `nix-config-terranix-drift` through runitor: success only when all
  are clean, `/fail` otherwise, and silence after a day's grace.
- **History:** `fleet-gauges` re-sends `summary.json` hourly as `terranix_drift_status{stack}`
  (0/1/2) plus `terranix_drift_last_run_timestamp_seconds`.
- **Runbook:** on a `/fail`, read `~/Library/Logs/terranix-drift.log` (counts only). Then read
  the stack's full plan in `$XDG_STATE_HOME/nix-config-terranix-drift/<stack>.log` (0600).
  Re-run by hand with `nix run .#terranix-drift -- --no-ping`. Drift is fixed with that stack's
  own `*-plan` and then an `*-apply`, which the operator runs. The check never applies.

### `infra/cloudflare/nixpi-tunnel.nix`

Declares `nixpi`'s **remotely-managed** Cloudflare Tunnel itself (the file is the full list):

- a `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`),
- its ingress (`cloudflare_zero_trust_tunnel_cloudflared_config`: SSH → `ssh://localhost:22`,
  one rule per `hostedSites` entry → the local Caddy at `http://localhost:80`, plus the
  mandatory catch-all `http_status:404`),
- one proxied `cloudflare_dns_record` CNAME per site → `<tunnel-id>.cfargotunnel.com`,
- per site that opts into www, a www CNAME plus a www→apex redirect (`cloudflare_ruleset`),
- the tunnel-health alert (`cloudflare_notification_policy`),
- the connector **token** surfaced as a sensitive `output` (via the
  `cloudflare_zero_trust_tunnel_cloudflared_token` data source),
- **the edge's TLS floor, DECLARED rather than clicked** — a `cloudflare_zone_setting` per
  setting (`ssl = strict`, `min_tls_version = 1.2`, `always_use_https`, HSTS) for the SSH
  host's zone **and** every hosted site's zone,
- **the SSH Access gate** — `cloudflare_zero_trust_access_application.nixpi_ssh`. Declaring it
  is not tidiness: that object **vanished once, on 2026-08-20**, and took `ssh` plus both deploy
  legs down with it. Declared, a rebuild restores the gate instead of a dashboard click.

What stays out-of-band, and why: [ADR-005 §10](../iac-coverage-adr.md).

A pure function of its `hostedSites`/`domainName`/`accountId`/`zoneId` module args (same
shape/default as `mkNixos`); `cf-tunnel-plan`/`cf-tunnel-apply` pass the fleet's real
`hostedSites` (`config.fleet.hostedSites`), while `cf-tunnel-destroy` deliberately
keeps the `[ ]` default so tearing the real stack down still needs the explicit
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
from `modules/parts/identity.nix` via `cachixUrl`/`cachixKey`. Read is public — only the substituter
URL + public key, **NO token on any consumer**. The write credential `CACHIX_AUTH_TOKEN` lives
in exactly two places: a **GitHub Actions secret** (used by `cachix/cachix-action` in every workflow that names `CACHIX_AUTH_TOKEN`, to push
build closures) and
— since 2026-08-21 — the operator's **login Keychain** (registered via `secret set`,
loader-exported like every personal token) for ad-hoc local `cachix push kattakath <paths>`;
never in Nix or git, and consumers still substitute tokenless (read stays public). Note the
token does NOT influence builds or substitution — Nix sandboxes scrub the environment, so it is
only ever consumed by the `cachix` CLI at push time.

### `infra/grafana/stack.nix` — the Grafana Cloud stack (ADR-012 step 2)

- **Adopted, not created.** Every object ADR-011 built by hand has an `import` block.
- **`resources.nix` is generated.** It came from `tofu plan -generate-config-out` plus a
  deterministic HCL-to-Nix conversion. A `builtins.toJSON` value is exactly what the provider stores.
- **Provider from nixpkgs** (`opentofu.withPlugins`, `grafana_grafana`; ADR-012 § 3), not
  `provider-pins.nix`.
- **Credentials:** `GRAFANA_AUTH` (service account `terranix`, Admin) and
  `GRAFANA_SM_ACCESS_TOKEN`, through `secret exec`. The Sheet id is the `ROLLUP_SHEET_ID`
  repository variable, read at run time.
- **Datasource secrets are never Terraform's:** `secure_json_data_encoded` is ignored, so the
  GitHub App, Sheets reader and Cloud Monitoring reader keys stay only in Grafana, never state.
- **Maps usage:** datasource `gcp-monitoring` (SA `grafana-monitoring-reader`, viewer-only),
  dashboard + rule group `maps-platform`. Queried live, so it costs no Grafana series.
- **Guards** (the same set as the github stack's): an empty-state guard (with no state, every
  resource must have an import block — `GRAFANA_ALLOW_CREATE`), a drop guard (a render that
  loses an object state holds refuses — `GRAFANA_ALLOW_DROPS`) and no `-auto-approve`.

### `infra/github/stack.nix` — fleet rulesets and variables (ADR-012 step 3)

Adopted by `import` blocks, like grafana. Repo registry: `infra/github/repos.nix`. The rest: its
header.

