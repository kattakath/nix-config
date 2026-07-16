# Exposing an MCP server as an OAuth-secured connector

How the Mac publishes the **kapture** MCP server to the public internet as an
**OAuth-gated connector** (usable from grok.com and any spec-compliant MCP
client), and how to operate it.

## What this is

kapture drives *this Mac's* Chrome (via the Kapture DevTools extension), so the
MCP origin must be the Mac. The Mac has no inbound network and nixpi's tunnel
can't reach it, so the Mac originates its **own** outbound Cloudflare Tunnel and
puts **Cloudflare Access "Managed OAuth"** in front of it.

```
Grok.com ──HTTPS──▶  mcp.kattakath.com            [ Cloudflare edge ]
                     ├─ Access self-hosted app + Managed OAuth
                     │     = OAuth 2.1 AS: RFC 8414/9728 discovery, PKCE, DCR,
                     │       /authorize (Google login), /token
                     ├─ Access policy: allow ONLY ismail@kattakath.com
                     ▼  (only authenticated, policy-passing requests continue)
                   Cloudflare Tunnel  ── "macos-mcp" connector on the Mac
                     ▼
                   mcp-proxy (kapture-ONLY) on 127.0.0.1:8099
                     ▼
                   kapture ─▶ your Chrome tab (DevTools extension)
```

Why this is secure: no secret in the URL. Auth is a real browser OAuth handshake
(confirmed: grok.com performs 401 → discovery → dynamic client registration →
`/authorize` w/ PKCE → token). The Access **policy** means even someone with the
URL cannot connect — only your Google identity passes. The origin is never
publicly reachable; Cloudflare enforces at the edge, then forwards down the
tunnel. Only kapture is exposed — the personal gateway on `:8096`
(memory/cloudflare/fetch/…) stays private.

## The moving parts (all declarative)

| Piece | Where |
|---|---|
| kapture-only mcp-proxy on `:8099` + Mac cloudflared connector (launchd user agents) | [modules/shared/mcp.nix](../modules/shared/mcp.nix) (`services.mcpGateway.publicServers` / `.publicTunnel`) |
| Opt-in for the Mac | [modules/shared/home.nix](../modules/shared/home.nix) (`services.mcpGateway` block, darwin-gated) |
| Tunnel + ingress + CNAME + **Access app (Managed OAuth) + policy** + token output | [infra/cloudflare/macos-mcp-tunnel.nix](../infra/cloudflare/macos-mcp-tunnel.nix) (terranix) |
| Port + operator email single sources | [flake.nix](../flake.nix) (`mcpPublicPort = 8099`, `operatorEmail`) |
| Provisioning apps | `nix run .#cf-mcp-apply` / `.#cf-mcp-destroy` |

The connector token is **never** in git or the store — it lives in the macOS
login Keychain (`MCP_TUNNEL_TOKEN`), read at launch by the connector agent.

## First-time setup

1. **Activate the Nix side** (starts the kapture-only proxy + the connector agent;
   the connector is inert until the token exists):
   ```bash
   darwin-rebuild switch --flake .#macos
   ```

2. **Provision the Cloudflare side** (tunnel + Access Managed-OAuth app + policy).
   Needs an API token with **Account: Cloudflare Tunnel:Edit + Access: Apps and
   Policies:Edit** and **Zone: DNS:Edit** on `kattakath.com`:
   ```bash
   CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-mcp-apply
   ```
   It prints the connector token with the exact store command.

3. **Store the token in the Keychain** (from the printed line):
   ```bash
   set-secret MCP_TUNNEL_TOKEN <token>
   ```
   Then kick the connector (or just re-login / re-switch):
   ```bash
   launchctl kickstart -k gui/$(id -u)/mcp-tunnel-connector
   ```

4. **Add the connector in Grok** (grok.com → Connectors → New → Custom):
   - **Server URL:** `https://mcp.kattakath.com/servers/kapture/sse`
     (`/servers/kapture/mcp` for Streamable HTTP)
   - Click **Add Connector** → a browser window opens → **log in with Google**
     (as `ismail@kattakath.com`). Grok stores the token and refreshes it
     automatically.

5. **Use kapture:** install the Kapture Chrome DevTools extension and open its
   panel on a tab — that's the browser kapture drives. Without it, `initialize`
   and `tools/list` work but automation calls have no tab to act on.

## Operations

- **Rotate the connector token:** `nix run .#cf-mcp-apply` again (or rotate in
  the dashboard), then `set-secret MCP_TUNNEL_TOKEN <new>` + kickstart.
- **Revoke a client / re-auth:** revoke the Access session in the Zero Trust
  dashboard; Grok re-runs the OAuth flow on next use.
- **Change who's allowed:** edit `operatorEmail` in [flake.nix](../flake.nix) (or
  broaden the policy `include` in the terranix module) and re-apply.
- **Publish another server:** add its name to `services.mcpGateway.publicServers`
  in [home.nix](../modules/shared/home.nix), switch, and it's served at
  `https://mcp.kattakath.com/servers/<name>/{sse,mcp}` behind the same OAuth gate.
- **Tear it all down:**
  ```bash
  CLOUDFLARE_API_TOKEN=<scoped> nix run .#cf-mcp-destroy
  ```
  and set `services.mcpGateway.publicTunnel.enable = false` (or remove the
  `home.nix` block) + switch. The connector stops; nothing is exposed.

## Notes / caveats

- **Provider schema:** the terranix module sets
  `oauth_configuration = { enabled = true; dynamic_client_registration.enabled = true; }`
  on the Access application. This matches the Cloudflare Terraform provider v5
  schema. If a future provider version rejects the nested
  `dynamic_client_registration` field, drop to just `enabled = true` (Managed
  OAuth may enable DCR by default) — Grok requires DCR, so keep it enabled one way
  or another.
- **Posture:** the Mac connector dials **out** to Cloudflare; it opens **no**
  inbound port. It's a deliberate, Access-gated exception to the Mac's
  no-incoming posture — one gated service reachable via Cloudflare's edge.
- **Google IdP** must already be configured in Cloudflare Zero Trust (it is). The
  login page offers all configured IdPs; the policy restricts to your email. To
  force Google and skip the chooser, set `allowed_idps` + `auto_redirect_to_identity`
  on the Access app (see the module comment).
