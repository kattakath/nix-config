---
name: cloudflared-tunnel
description: >
  Set up the Cloudflare Tunnel CLIENT path on macOS — provision a remotely-managed (token) tunnel
  for a host via `scripts/cf-one-provision.sh`, and reach a NixOS host over SSH via a ProxyCommand.
  Use when asked to "set up a cloudflare tunnel", "expose SSH over cloudflare", "reach a host over
  the tunnel", or configure a "cloudflared proxycommand". Pairs with agenix-host-rekey (the
  host-side tunnel-token secret) and the nixarm host profile.
---

# Cloudflare Tunnel (client + DNS + SSH ProxyCommand)

## Gotchas (read first)

- **Remotely-managed (token) tunnels — no interactive login.** This repo does NOT use
  `cloudflared tunnel login` / `cert.pem` / a local credentials JSON. Each host's tunnel, connector
  token, and proxied CNAME `<host>.kattakath.com` are provisioned in the Cloudflare account via the
  Cloudflare API by `scripts/cf-one-provision.sh`. There is no `~/.cloudflared/cert.pem` to babysit.
- **Direct port 22 is NOT reachable and that is expected.** `nixarm.kattakath.com` resolves to a
  Cloudflare edge IP (`172.64.x.x`), not the host. Traffic only flows through the tunnel — never
  diagnose the tunnel by `nc -z host 22` against the public name.
- **Verified-working signature:** once connected, `$SSH_CONNECTION` on the host shows `::1` —
  cloudflared terminates the tunnel and the SSH session arrives on the host as `localhost:22`.
- The NixOS/macOS host side and the agenix host-key handoff live in sibling skills — don't
  re-derive them here.

## 1. Provision the tunnel + token + DNS (Cloudflare API)

Provision the per-host tunnel, its connector token, and the proxied CNAME `<host>.kattakath.com`
entirely in the Cloudflare account — no browser login, no `cert.pem`:

```bash
scripts/cf-one-provision.sh nixarm             # creates tunnel + token + nixarm.kattakath.com CNAME
dig +short nixarm.kattakath.com                # → a 172.64.x edge IP (NOT the host) — expected
```

The connector **token** (a single `TUNNEL_TOKEN=…` line) is what the tunnel-TARGET host needs. Only
the **NixOS** hosts (`nixarm`/`nixrpi`/`nixamd`) run a connector: the token becomes the agenix secret
`nixarm-tunnel-token.age`, decrypted at boot and fed to the connector via `EnvironmentFile` (encrypt +
rekey via the **agenix-host-rekey** skill). The **macOS** hosts (`nixcon`/`nixtel`) are tunnel
CLIENTS only — they run no connector and no sshd, so they need no token; see §5 for the client path.

## 2. Host side (cross-reference)

`modules/nixos/cloudflared.nix` runs a hardened `systemd.services.cloudflared-connector`
(`cloudflared --no-autoupdate tunnel run`) that reads `TUNNEL_TOKEN` from the agenix-decrypted
`EnvironmentFile` (`config.age.secrets."<host>-tunnel-token".path`); the ingress `ssh://localhost:22`
lives in the Cloudflare account. The secret must be re-encrypted to the host's SSH host key before
the connector can decrypt it at activation — that is the **agenix-host-rekey** skill. This connector
runs on the NixOS hosts only; the macOS hosts (`nixcon`/`nixtel`) run no connector and no sshd — they
are tunnel CLIENTS (see §5). Do not edit `hosts/` or `*.nix` from this skill; it is the client/DNS
playbook.

## 5. macOS client — reach the host via SSH ProxyCommand

Declarative (Home-Manager, in `modules/shared/home.nix`-style config):

```nix
programs.ssh.matchBlocks."nixarm.kattakath.com" = {
  user = "ismail";
  proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
};
```

Ad-hoc test (no config change):

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" ismail@nixarm.kattakath.com
```

Verify it actually went through the tunnel:

```bash
ssh ismail@nixarm.kattakath.com 'echo $SSH_CONNECTION'    # → ::1 ...  (localhost = tunnel-terminated)
```

## Phase 2 (optional) — Cloudflare Access policy

Adding a Cloudflare **Access** application/policy on `nixarm.kattakath.com` puts an identity gate in
front of the SSH layer (defense-in-depth). This is a **Cloudflare dashboard step**, not a `cloudflared`
CLI action — configure it in the Zero Trust dashboard, then `cloudflared access ssh` will prompt for
the Access login before the SSH handshake.
