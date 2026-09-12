# Publishing MCP servers — design note

**Status:** **BUILT and live** as of 2026-09-12. v2 rewrote a v1 that answered the wrong question
(see §9); §7/§7a were revised again the same day, when `character-mcp` migrated off its own OAuth
onto the shared service token.

**The ask, verbatim:** *"Can we integrate this feature with our `mcp.nix` so that by flipping a
flag, an MCP server can be made reached public with connector protection?"* — i.e. publish
servers **that already run on the localhost gateway**, not write new ones.

**Verdict:** achievable, and Cloudflare documents the exact mechanism. One flag per server; the
tunnel, DNS, Access app and service token are created **once**, never per server.

---

## 1. Target shape

```
┌────────────────────────┐
│      claude grok       │
└────────────┬───────────┘
             ▼
┌────────────────────────┐
│       mcp portal       │   one client URL, already exists
└────────────┬───────────┘
             ▼
┌────────────────────────┐
│  Access service token  │   non-interactive auth, headers
└────────────┬───────────┘
             ▼
┌────────────────────────┐
│   cloudflared on mac   │   OUTBOUND only, no inbound port
└────────────┬───────────┘
             ▼
┌────────────────────────┐
│  public gateway :8097  │   second mcp-proxy process
└────────────┬───────────┘
             ▼
┌────────────────────────┐
│only public=true servers│
└────────────────────────┘
```

---

## 2. The mechanism that makes it work

Provider schema for `cloudflare_zero_trust_access_ai_controls_mcp_server.auth_credentials`,
verbatim:

> Static credential for the upstream MCP server. For auth_type "bearer", either a raw token
> string … or a JSON-encoded object of the form `{"headers":{"Header-Name":"value",…}}` for
> custom or multiple static headers **(e.g. Cloudflare Access service tokens:
> `{"headers":{"cf-access-client-id":"…","cf-access-client-secret":"…"}}`)**.

So the **portal authenticates to an Access-protected origin non-interactively**. That is the
piece that makes a flag sufficient: clients keep talking to the portal, the portal holds the
service token, and the gateway never needs its own OAuth.

Confirmed present in the pinned provider:

| Resource | Purpose |
|---|---|
| `cloudflare_zero_trust_access_ai_controls_mcp_server` | one per published server |
| `cloudflare_zero_trust_access_ai_controls_mcp_portal` | the portal + its `servers` list |
| `cloudflare_zero_trust_access_application` / `_policy` | the one Access app + service-token policy |
| `cloudflare_zero_trust_tunnel_cloudflared` / `_config` | the Mac-side connector |
| `cloudflare_dns_record` | the single gateway hostname |

---

## 3. The decisive constraint: a SECOND gateway process

**Do not tunnel the existing `:8096`.**

Access protects a **hostname**, not a path. Tunnel today's gateway and a leaked service token
reaches *every* path on it — 7 Gmail accounts, production WordPress, Postgres, Telegram.
Per-path Access apps would fix that, but that is per-server Zero Trust config again, i.e. the
exact toil this design exists to remove.

Instead, run a **second `mcp-proxy`** on `:8097` whose config is built from the `public = true`
subset.

| Property | Result |
|---|---|
| Leaked service token reaches | **only published servers** |
| Unpublished servers | **not in that process** — structurally unreachable, not merely unrouted |
| Crash blast radius | private gateway unaffected (they are separate agents) |
| `mcp.nix` delta | same `mkConfig`, filtered list, second launchd agent |

`desktop-commander` and `open-design` become ineligible **for free**: they are stdio-only and
never enter `endpoints`, so there is nothing to flag.

---

## 4. Cost per server — the actual answer to the ask

| Created **once** | Per new public server |
|---|---|
| cloudflared connector on macos | — |
| 1 DNS record (the gateway hostname) | — |
| 1 Access application + 1 service token | — |
| the `:8097` launchd agent | — |
| the portal itself + its DCR allowlist | — |
| | **one entry in the `public` list** |

**`public = [ … ]` → activate + apply → published.** No new DNS, no new hostname, no new
credential.

### Correction (2026-09-12): one flag, but THREE Cloudflare objects

v2 of this note said the per-server cost was "one portal `mcp_server` entry". That was wrong,
and the way it was wrong is the interesting part: **registering a server and publishing it are
different things**, and the failure mode is silent.

| Object | Without it |
|---|---|
| `..._mcp_server` (the registration) | nothing exists |
| `..._mcp_portal.servers[]` (attachment) | registration reaches `status = "ready"`, tools discovered, and **no client can see it** |
| `..._access_application` `type = "mcp"` + an Allow policy | attached, and **still** invisible to clients |

Measured, in that order: three registrations `ready` and the portal served **nothing**; then all
three attached and the portal listed **one** — the only one that happened to have an `mcp`-type
Access app, created by hand in 2026-09-07.

All three are still generated from the **one** list entry, so the operator-facing cost is
unchanged. What changed is that the module has to emit all three — and that **testing at the
origin does not detect this**. The origin answered `200` with its service token the entire time
the portal was empty. Verify a publish through `mcp.<domain>`, never through the origin.

## 5. Flag surface in `mcp.nix`

Today the split is list membership plus one `//` (see `hostedServerNames` → `endpoints` →
`httpEntries`). This adds a third tier:

```
stdio-only   ·   localhost HTTP   ·   localhost HTTP + published
```

Proposed:

```nix
services.mcpGateway.public = [ "nixos" "context7" "memory" ];
```

A list, not a per-server attribute, so the default is **empty** — opt-in by construction. The
module then derives the `:8097` config, the tunnel ingress, and the portal registrations from
that one list, the way `hostedSites` already drives ingress + DNS + rulesets.

### Assertions the module must carry

| Assertion | Why |
|---|---|
| every name ∈ `hostedServerNames` | cannot publish something the gateway does not host |
| name ∉ the two client-stdio servers | RCE / silent-death servers structurally ineligible |
| default `[ ]` | opt-in, never deny-by-omission |

---

## 6. Known limits — decide with these visible

| Limit | Detail |
|---|---|
| **The Mac must be awake and online** | the gateway is on the laptop. Sleep it and every published server goes dark. Servers needing real uptime belong on `nixpi`, not here. |
| **Two commands, not one** | `activate` handles the Mac side (agent + tunnel config). The Cloudflare side is a terranix apply. Wiring both to one list still leaves two applies. |
| **Shared fate within the public gateway** | one `mcp-proxy` process; a crash darks all published servers (but not the private ones). |
| **Access is the only boundary** | unlike `character-mcp`, the gateway has no OAuth of its own. §3's second process is what bounds the damage. |
| **Portal costs** | brokering drops independent MFA / purpose justification; logs are dashboard-only (Logpush is Enterprise); DLP does not apply to portal traffic; the feature is beta. |

---

## 7. External Workers: same flag, same credential (settled 2026-09-12)

For a server that must be up when the Mac is asleep, or that wants its own origin, a standalone
Worker on its own single-label subdomain is still the answer. What changed is **how it is
authenticated**: it now rides the *same* Access service token as the gateway, declared as an
`externalServers` entry rather than running its own OAuth.

```nix
externalMcpServers = [
  { name = "character"; host = "character.kattakath.com"; id = "character-mcp"; }
];
```

That one entry renders **both** halves: an Access application over the hostname bound to the
shared service-token policy, and the portal registration with `auth_type = "bearer"`.

| | Before (OAuth per Worker) | After (shared service token) |
|---|---|---|
| Credentials the portal holds | one per origin | **one, total** |
| Worker code needed | full OAuth 2.1 AS + consent page + DCR | a ~40-line JWT verifier |
| Client bypassing the portal | **possible** — drive the Worker's OAuth directly | **impossible** — no AS to drive |
| Tool gating | advisory | **enforced** |

### Why this replaced the per-Worker OAuth shape

The old invariant was *"every publicly reachable server must be safe when the portal is
bypassed"* — an acknowledgement that bypass could not be prevented. It was proven
non-theoretical on 2026-09-12: Grok could not use the portal (the DCR allowlist is Claude-only),
connected **direct** to `character.kattakath.com`, and was granted `character:write`, so the
portal's tool gating did not apply.

Migrating that Worker to bearer removed the bypass instead of documenting it. Dropping
`OAuthProvider` also deleted an **unauthenticated** `POST /oauth/register` that accepted any
`redirect_uri` — deferred audit item #5, closed as a side effect.

**Cost, stated so it is a choice:** Grok-direct is gone permanently, and there is no scope model
left — the tool set is the whole grant. The migration is a `tofu` **replace**, not an update:
`auth_type` is ForceNew in the provider, so oauth → bearer destroys and recreates the
registration (keeping its stable `id`, so the portal-side `type = "mcp"` app re-binds).

### The Worker still verifies the assertion itself

Access is the boundary, but the origin does not trust the network alone. `worker/access.ts` pins
`iss`, the application's `aud`, and the service token's `common_name`. Without the `aud` pin, any
Access application in the account would be a skeleton key for this one.

### Two Access apps per external server is CORRECT, not a duplicate

The dashboard shows two entries named for one server. They are different layers and both must
stay:

| App | `type` | Gates |
|---|---|---|
| `MCP character (service token)` | `self_hosted` on `character.kattakath.com` | the **origin** — who may reach the Worker at all |
| `character-mcp` | `mcp`, `destinations: [{via_mcp_server_portal}]` | the **portal** — who may use this server *through* `mcp.kattakath.com` |

Deleting the second would not tighten anything; it would unpublish the server from the portal.
What *was* redundant and got deleted on 2026-09-12 is a **third**, older app —
`character-mcp /authorize`, path-scoped to an endpoint that no longer exists. Because Access
matches most-specific-path-first, it had been **shadowing** the hostname app and answering
`/authorize` with a 302 to a login page.

---

## 7a. Redirect-URI allowlists — now a non-problem

**Obsolete as of 2026-09-12.** This section described maintaining DCR allowlists across the portal
*and* each Worker's own OAuth. Under §1 the gateway never had OAuth (it uses a service token), and
§7 removed the last Worker that did. There is exactly one allowlist left — the portal's
`dynamic_client_registration.allowed_uris`, listing the *end clients* (Claude, Grok).

The "enforcement lever" recorded here as **DECLINED** (tightening each Worker's DCR to the portal
callback, to close audit finding MCP-5) is **moot**: the Workers have no DCR to tighten. MCP-5 is
closed by removal, at none of the cost that was declined.

---

## 8. Open decisions

1. ~~Hostname for the public gateway~~ — **`connector.kattakath.com`**, single-label as required
   (the free Universal cert covers `*.kattakath.com`, one label only).
2. ~~Which servers to publish first~~ — **`memory` + `sequential-thinking`**. Both tokenless.
3. **Does anything belong on `nixpi` instead**, given §6's uptime limit? Still open.
4. **Add Grok's redirect URI** to the portal allowlist? Now the *only* way Grok can reach any of
   this — §7 removed its direct path. Still open, and now load-bearing rather than optional.
5. ~~Prune two stale `playground-*` OAuth clients in `OAUTH_KV`~~ — **moot**: nothing reads that
   namespace any more. Deleting the namespace itself is a separate destructive step, not done.

---

## 9. Correction record — what v1 of this note got wrong

v1 recommended writing a new Worker per public server and dismissed the tunnel approach. Two of
its four objections were wrong or weak, and it answered a question that had not been asked.

| v1 claim | Correction |
|---|---|
| *"requires incoming traffic to the client Mac, inverting the fleet's shape"* | **Wrong.** `cloudflared` dials **outbound**; no inbound listener, no port opened. The Pi already demonstrates this. |
| *"path filtering is deny-by-omission — new servers exposed by default"* | **Solvable, and by the proposed flag itself.** A `public` list defaulting to `[ ]` is opt-in. §3 goes further and makes unpublished servers structurally absent. |
| *"shared fate — one crash darks all"* | Still true, but bounded by §3's second process, and it is an availability concern, not a security one. |
| *"blast radius behind the filter"* | Still true but **graded** — v1 treated `nixos` (read-only, no token) as equivalent to `desktop-commander` (RCE). §3 addresses it structurally. |

Kept from v1 because it remains correct: the invariant in §7, the redirect-URI analysis in §7a,
and the verified provider-resource list in §2.
