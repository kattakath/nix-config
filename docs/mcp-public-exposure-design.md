# Publishing MCP servers — design note

**Status:** design, nothing built. Written 2026-09-12 after the Cloudflare/Zero-Trust audit,
prompted by a concrete ask: *"I don't want to maintain DNS records and Zero Trust config every
time an MCP server is added or removed."*

**Verdict up front:** a public MCP server should be its **own Worker on its own single-label
subdomain**, generated from one list entry in terranix — **not** a published path on the
localhost gateway. The toil goes away by *generating* the DNS/Access objects, not by avoiding
them.

---

## 1. What exists today

Two unrelated things share the letters "MCP". Conflating them is the main hazard here.

| | `modules/shared/mcp.nix` | `mcp.kattakath.com` |
|---|---|---|
| What | localhost gateway, `mcp-proxy` on `127.0.0.1:8096` | Cloudflare MCP Server Portal (beta) |
| Hosts | ~19–21 servers as one launchd user agent | downstream remote MCP servers |
| Reachable | **nothing off-box** — no tunnel, no Access | public, Access-gated |
| Today serves | Claude Code, VS Code, Claude Desktop, Grok CLI | `character-mcp` (1 server) |

### How the gateway decides HTTP vs stdio

There is **no flag**. It is list membership plus one `//`:

```
customStdioServers  ──┐
                      ├──> hostedServerNames ──> endpoints ──> httpEntries ──┐
packagedServerNames ──┘                                                      │
                                                                             ▼
                        programs.claude-code.mcpServers = httpEntries // { … stdio … }
```

Everything in `httpEntries` is reachable over HTTP on loopback. Two servers are merged in
**after** and therefore never enter `endpoints` at all:

| Server | Why it is not hosted |
|---|---|
| `desktop-commander` | shell/**RCE** surface — deliberately per-client |
| `open-design` | stdio-only upstream **and** a silent-death bug; one crashing server **darks the whole gateway** |

> **Naming trap:** `customStdioServers` are *not* stdio to clients. They are stdio
> *subprocesses* that `mcp-proxy` adapts to HTTP. The genuinely client-stdio ones are the two
> in the `//` block. Do not "fix" one by reading the other's name.

---

## 2. The constraint that decides the design

**The gateway is one process, on one host, with one fate.**

- It is a single launchd user agent bound to `127.0.0.1:8096`.
- Servers are **paths on it** (`/servers/<name>/mcp`), not separate listeners.
- `open-design`'s exclusion is documented precisely because one server crashing takes the
  whole gateway down.

So "expose one server" does not decompose. Publishing a path publishes **the gateway process**,
and any path-based restriction is a filter in front of a shared, high-privilege surface whose
other paths include 7 Gmail accounts, production WordPress, Postgres, and — one `//` away —
RCE.

It also runs on **macos**, which by design takes **no incoming traffic**; the only tunnel
connector in the fleet runs on `nixpi`. Publishing from the Mac means a *new* connector on the
client machine, inverting a deliberate property of the fleet.

**This is the argument against Option A below, and it is decisive.**

---

## 3. Options

### A. Publish gateway paths through a tunnel — **rejected**

Add a cloudflared connector on macos, ingress to `127.0.0.1:8096`, Access in front, restrict by
path.

| | |
|---|---|
| ✅ | reuses everything already running; no new server code |
| ❌ | shared-fate process: one crash darks every published server |
| ❌ | the blast radius behind the filter is RCE + 7 mailboxes + prod DB |
| ❌ | requires incoming traffic to the *client* Mac, inverting the fleet's shape |
| ❌ | path-filtering is deny-by-omission — a new gateway server is exposed **by default** |

That last row is the killer: safety would depend on remembering to exclude, and the audit found
exactly that failure mode elsewhere (`allowedTCPPorts` looked restrictive and did nothing).

### B. One Worker per public server — **recommended**

The `character-mcp` shape, generalised: each public server is its own Cloudflare Worker on its
own single-label subdomain, with its own OAuth, registered into the portal.

| | |
|---|---|
| ✅ | **independent fate** — one server's bug cannot touch another |
| ✅ | nothing on the Mac is exposed; the localhost gateway keeps its "no remote path" property |
| ✅ | safe **by construction** when the portal is bypassed (each has its own auth) |
| ✅ | fully declarable — see §5 |
| ❌ | each needs a Worker written and deployed (code, not just config) |
| ❌ | one DNS record per server — unavoidable, see §6 |

### C. Hybrid — gateway published, Workers for the rest

Inherits A's shared-fate and default-exposed problems for no gain. **Rejected.**

---

## 4. The invariant — adopt before server #2

> **Every publicly reachable MCP server must be safe when the portal is bypassed.**

Not theory. On 2026-09-12 Grok could not use the portal (its DCR allowlist is Claude-only), so
it connected **direct** to `character.kattakath.com` and was granted `character:write` — the
portal's per-tool gating (`4/6`, writes disabled) **did not apply**. Nothing was exposed to
anyone else, because that Worker enforces its own OAuth + Access + a hardcoded email allow-list.

**A server that trusts the portal for authentication would have been open at its own URL.**

Concretely, every public server must have:

1. its own OAuth (`authorization_endpoint` / `token_endpoint` / `register`),
2. its own Access application on `/authorize`,
3. the Access **`aud` hardcoded in the Worker** — this is what stops a token minted for a
   *different* Access app authorising here,
4. its own allow-list of principals.

`auth_type` is a **required** field on the Terraform MCP-server resource. The module should
accept only `oauth`, turning this invariant into something that fails at eval.

---

## 5. What can be generated (verified against the pinned provider)

`tofu providers schema -json` confirms all four resources exist — the beta API is **not**
dashboard-only:

| Resource | Required fields |
|---|---|
| `cloudflare_workers_custom_domain` | `account_id`, `hostname`, `service` |
| `cloudflare_zero_trust_access_application` | *(all optional)* |
| `cloudflare_zero_trust_access_ai_controls_mcp_server` | `account_id`, `auth_type`, `hostname`, `id`, `name` |
| `cloudflare_zero_trust_access_ai_controls_mcp_portal` | `account_id`, `hostname`, `id`, `name` (+ optional `servers`, `code_mode`, `allow_code_mode`) |

Proposed shape, mirroring `hostedSites` (new file, e.g. `infra/cloudflare/mcp-servers.nix`):

```nix
mcpServers = [
  { name = "character"; worker = "character-mcp"; }
  { name = "notes";     worker = "notes-mcp";     }
];
```

Each entry generates: the Workers custom domain, the `/authorize` Access application plus its
policy attachment, the portal server registration, and membership in the portal's `servers`
list. **Add a server = one line. Remove = delete the line.** `tofu plan` shows exactly what
changes, the same way site CNAMEs already work.

### Assertions the module should carry

| Assertion | Why |
|---|---|
| `name` is **single-label** | the free Universal cert covers `*.kattakath.com` — **one** label. `calendly.ismail.kattakath.com` had no cert for exactly this reason. |
| `auth_type == "oauth"` | §4's invariant, enforced at eval |
| name not in the localhost gateway's roster | prevents accidentally publishing a gateway server by name collision |

---

## 6. What this does *not* remove

| Still manual / unavoidable | Why |
|---|---|
| **One DNS record per server** | Cloudflare's portal reaches downstreams **over HTTP**; it needs a URL. It becomes *generated output*, not hand-maintained state — but it does not vanish. |
| The Worker's own code | Terraform deploys; it does not write the handler. Copy `character-mcp`'s OAuth scaffolding. |
| Per-server OAuth | lives in the Worker source (see §4) |

---

## 7. Known costs of routing through the portal

| Cost | Detail |
|---|---|
| **MFA is dropped** | Cloudflare docs: independent MFA, purpose justification and temporary auth are **not enforced** for servers authorised through a portal. Pinning `allowed_idps` is the only remaining lever — already set to Google. |
| Logs are dashboard-only | the `mcp_portal_logs` Logpush dataset is Enterprise |
| No DLP on portal traffic | DLP AI prompt profiles explicitly do not apply |
| Beta | field semantics can change; per-server auth (§4) is the safety net |
| DCR allowlist | currently `claude.ai` + `claude.com` only. Any other client (Grok) is rejected and will go **direct** unless its redirect URI is added. |

---

## 7a. Redirect-URI allowlists — one, not one per server

A per-server allowlist is **not** needed. There are two distinct lists and only one is
maintained:

| List | Who registers there | Redirect URI | Maintenance |
|---|---|---|---|
| **Portal** `oauth_configuration.dynamic_client_registration.allowed_uris` | end **clients** (Claude, Grok) | one per client | the one you edit |
| **Each Worker's own DCR** | **the portal itself** | a single stable value | zero, if templated |

Per the provider schema for `is_shared_oauth_callback_enabled`: the gateway worker uses either
*"the shared Cloudflare-owned OAuth callback endpoint … instead of the customer portal
hostname"*. Default is off, so it is the portal hostname. Either way it is **one callback per
portal**, identical for every downstream — confirmed in `character-mcp`'s `OAUTH_KV`, where the
portal is registered as `https://mcp.kattakath.com/servers-callback`.

So a new server needs **no** redirect-URI work: template the Worker to accept the portal
callback and it is done.

### The enforcement lever — considered and DECLINED 2026-09-12

Workers currently ship `workers-oauth-provider`'s **open DCR** (any `redirect_uri`). That is how
Grok registered directly and received `character:write`, bypassing the portal's `4/6` tool
gating. Restricting each Worker's DCR to only the portal callback would make portal-only access
**enforced** rather than hoped-for, and would close audit finding MCP-5 as a side effect.

**Not adopted.** The cost is breaking Grok's existing direct grant and re-establishing it
through the portal, which the operator judged not worth it now. Consequence, stated plainly so
it is a choice and not a surprise: **the portal's tool gating is advisory for any client that
connects direct.** Revisit when a second public server exists, since the same open DCR would
apply to it too.

## 8. Decisions still needed

1. **Add Grok's redirect URI to the portal allowlist?** It is
   `https://grok.com/connectors-oauth-exchange-code/` (read from `OAUTH_KV`). Adding it does not
   by itself move Grok onto the portal — Grok would also have to be reconnected to the portal
   URL. Widening the allowlist also widens who may register OAuth clients.
2. **Portal session duration** is still `24h` (only `nixpi SSH` was cut to `1h`).
3. **Does the tool-gating benefit justify the portal at all** while there is one server? Its
   value is aggregation; with N=1 it is an extra hop earning only the tool switches and the call
   log. It pays off at N≥2 — which is the stated direction.
