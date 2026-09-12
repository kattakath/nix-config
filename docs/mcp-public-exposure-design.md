# Publishing MCP servers — design note

**Status:** design, nothing built. Rewritten 2026-09-12 (v2) after the first version answered
the wrong question — see §9.

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
| | **one portal `mcp_server` entry, generated from the flag** |

**`public = true` → activate → published.** No new DNS, no new Zero Trust objects.

---

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

## 7. Alternative that remains valid: a standalone Worker

For a genuinely new remote server — one that should be up when the Mac is asleep, or that wants
its own OAuth — the `character-mcp` shape still applies: its own Worker, own single-label
subdomain, own OAuth, `aud` hardcoded, registered in the portal. That is a *different* answer to
a *different* need, not a competitor to §1.

**Invariant for that path:** every publicly reachable server must be safe when the portal is
bypassed. Proven non-theoretical on 2026-09-12 — Grok could not use the portal (DCR allowlist is
Claude-only), connected direct to `character.kattakath.com`, and was granted `character:write`,
so the portal's `4/6` tool gating did not apply.

---

## 7a. Redirect-URI allowlists — one, not one per server

| List | Who registers | Maintenance |
|---|---|---|
| **Portal** `dynamic_client_registration.allowed_uris` | end clients (Claude, Grok) | the one you edit |
| Each Worker's own DCR | the portal itself | zero — one stable callback |

The portal registers against every downstream with a single callback —
`https://mcp.kattakath.com/servers-callback`, read from `character-mcp`'s `OAUTH_KV`. Identical
for every server. **Under §1 this does not arise at all**: the gateway uses a service token, not
OAuth.

### Enforcement lever — considered, DECLINED 2026-09-12

Restricting each Worker's DCR to only the portal callback would make portal-only access
**enforced** rather than advisory (and close audit finding MCP-5). Not adopted: it breaks Grok's
existing direct grant. Consequence, recorded so it is a choice and not a surprise: **portal tool
gating is advisory for any client that connects direct.** Revisit at server #2.

---

## 8. Open decisions

1. **Hostname for the public gateway** — e.g. `gw.kattakath.com`. Must be **single-label**: the
   free Universal cert covers `*.kattakath.com`, one label only (`calendly.ismail.kattakath.com`
   had no cert for exactly this reason).
2. **Which servers to publish first.** Suggest starting with read-only, tokenless ones
   (`nixos`, `context7`, `memory`, `fetch`) to exercise the path before anything credentialed.
3. **Does anything belong on `nixpi` instead**, given §6's uptime limit?
4. **Add Grok's redirect URI** (`https://grok.com/connectors-oauth-exchange-code/`) to the portal
   allowlist, so Grok uses the portal rather than going direct?
5. **Prune two stale `playground-*` OAuth client registrations** sitting in `character-mcp`'s
   `OAUTH_KV` from Cloudflare AI-playground testing.

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
