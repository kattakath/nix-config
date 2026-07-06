---
name: cloudflared-tunnel
description: >
  Set up the Cloudflare Tunnel CLIENT path on macOS — provision a remotely-managed (token) tunnel
  for nixpi via `scripts/cf-one-provision.sh`, and reach it over SSH via a ProxyCommand. Use when
  asked to "set up a cloudflare tunnel", "expose SSH over cloudflare", "reach nixpi over the
  tunnel", or configure a "cloudflared proxycommand". Pairs with the nixpi host profile
  (`modules/nixos/cloudflared.nix`).
---

# Cloudflare Tunnel (client + DNS + SSH ProxyCommand)

## Gotchas (read first)

- **Remotely-managed (token) tunnels — no interactive login.** This repo does NOT use
  `cloudflared tunnel login` / `cert.pem` / a local credentials JSON. The tunnel, connector
  token, and proxied CNAME `nixpi.kattakath.com` are provisioned in the Cloudflare account via
  the Cloudflare API by `scripts/cf-one-provision.sh`. There is no `~/.cloudflared/cert.pem` to
  babysit.
- **Direct port 22 is NOT reachable and that is expected.** `nixpi.kattakath.com` resolves to a
  Cloudflare edge IP (`172.64.x.x`), not the host. Traffic only flows through the tunnel — never
  diagnose the tunnel by `nc -z host 22` against the public name.
- **Verified-working signature:** once connected, `$SSH_CONNECTION` on the host shows `::1` —
  cloudflared terminates the tunnel and the SSH session arrives on the host as `localhost:22`.
- Only `nixpi` (the LIVE Raspberry Pi 4 server) runs a connector. `nixvm` is a sandbox VM with no
  public ingress. `macos` is a client only.

## 1. Provision the tunnel + token + DNS (Cloudflare API)

Provision the tunnel, its connector token, and the proxied CNAME `nixpi.kattakath.com` entirely
in the Cloudflare account — no browser login, no `cert.pem`:

```bash
scripts/cf-one-provision.sh nixpi              # creates tunnel + token + nixpi.kattakath.com CNAME
dig +short nixpi.kattakath.com                 # → a 172.64.x edge IP (NOT the host) — expected
```

The connector **token** (a single `TUNNEL_TOKEN=…` line) is what `nixpi` needs. Place it as
`/etc/secrets/cloudflared-token` on the host — a plain, operator-placed file, never committed to
git (see the secrets model in `CLAUDE.md` — there is no agenix/sops/encryption step in this repo).

## 2. Host side (cross-reference)

`modules/nixos/cloudflared.nix` runs a hardened `systemd.services.cloudflared-connector`
(`cloudflared --no-autoupdate tunnel run`) that reads `TUNNEL_TOKEN` from
`/etc/secrets/cloudflared-token`; the ingress `ssh://localhost:22` lives in the Cloudflare
account. Do not edit `hosts/` or `*.nix` from this skill; it is the client/DNS playbook.

## 3. macOS client — reach nixpi via SSH ProxyCommand

Declarative (Home-Manager, in `modules/shared/home.nix`-style config):

```nix
programs.ssh.matchBlocks."nixpi.kattakath.com" = {
  user = "ismail";
  proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
};
```

Ad-hoc test (no config change):

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" ismail@nixpi.kattakath.com
```

Verify it actually went through the tunnel:

```bash
ssh ismail@nixpi.kattakath.com 'echo $SSH_CONNECTION'    # → ::1 ...  (localhost = tunnel-terminated)
```

On the LAN, skip the tunnel entirely: `ssh ismail@nixpi.local` (mDNS).

## Phase 2 (optional) — Cloudflare Access policy

Adding a Cloudflare **Access** application/policy on `nixpi.kattakath.com` puts an identity gate in
front of the SSH layer (defense-in-depth). This is a **Cloudflare dashboard step**, not a `cloudflared`
CLI action — configure it in the Zero Trust dashboard, then `cloudflared access ssh` will prompt for
the Access login before the SSH handshake. See the **cloudflare-one** skill for the broader CF One
adoption this repo is moving toward (MCP aggregation), which is the reason the LiteLLM container path
was dropped.
