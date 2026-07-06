---
name: cloudflared-tunnel
description: >
  Set up Cloudflare Access for Infrastructure (ZTIA) SSH for nixpi — short-lived SSH
  certificates over the existing Cloudflare Tunnel connector, gated by an Access policy and
  delivered via the Cloudflare One Client (WARP). Use when asked to "set up ZTIA SSH", "reach
  nixpi over Cloudflare", "provision the SSH CA", "cf-ssh-apply", or configure WARP-enrolled
  SSH access. Pairs with `modules/nixos/cloudflared.nix` (connector, unchanged),
  `modules/nixos/core.nix` (`services.openssh-ca-trust`), and
  `infra/cloudflare/nixpi-ssh.nix` (terranix).
---

# Cloudflare Access for Infrastructure (ZTIA) SSH for nixpi

## Gotchas (read first)

- **The Cloudflare Tunnel connector is UNCHANGED.** ZTIA does not replace
  `cloudflared-connector` (`modules/nixos/cloudflared.nix`) — it adds an
  identity + short-lived-certificate layer on top of the same tunnel. Do not
  touch that module or `/etc/secrets/cloudflared-token` for this work.
- **Client requirement changed: Cloudflare One Client (WARP), not just
  `cloudflared` CLI.** ZTIA requires the client device to be enrolled in the
  Zero Trust org and running the WARP client in Traffic-and-DNS mode with the
  Gateway TCP proxy on. A bare `cloudflared` binary is no longer sufficient
  for the SSH path.
- **No Terraform resource for the SSH CA itself.** Generating the CA
  (`gateway_ca`) is dashboard- or bare-API-only
  (`POST /accounts/$ACCOUNT_ID/access/gateway_ca`) — confirmed absent from the
  current Cloudflare Terraform provider docs. `infra/cloudflare/nixpi-ssh.nix`
  therefore only provisions the target/application/policy; the CA public key
  is captured by hand and committed to `modules/nixos/cloudflare-ssh-ca.pub`.
- **Rollout is ORDERED and has a lockout risk.** Never flip
  `services.openssh-ca-trust.removeStaticKey = true` on `nixpi` before
  verifying an end-to-end ZTIA login from an enrolled client. See the full
  runbook in `docs/tunnel-architecture-and-runbook.md` §9 — this skill
  summarizes it, that doc is authoritative.
- **`nixvm` is explicitly excluded.** It keeps the shared static SSH key and
  never sets `services.openssh-ca-trust.enable` — it's a LAN/serial-console
  sandbox, not part of this cutover. Do not add ZTIA to `hosts/nixvm.nix`.
- **Physical console (getty) is always the break-glass path**, independent of
  whichever SSH auth method is active.

## 1. Provision the Cloudflare-side ZTIA objects (terranix -> OpenTofu)

```bash
CLOUDFLARE_API_TOKEN=<token with Account Zero Trust:Edit> nix run .#cf-ssh-apply
```

This renders `infra/cloudflare/nixpi-ssh.nix` and applies:

- a `cloudflare_zero_trust_infrastructure_access_target` (hostname label + IP + virtual network — **fill in the placeholder `targetIp`/`virtualNetworkId` in that file first**),
- a `cloudflare_zero_trust_access_application` (`type = "infrastructure"`, SSH/22, `target_criteria`),
- a `cloudflare_zero_trust_access_policy` (`decision = "allow"`, the owner's `email_domain`, plus `connection_rules.ssh.usernames = ["ismail"]`).

Tear down with `nix run .#cf-ssh-destroy` (same token requirement).

**Prerequisite you may still need**: a Tunnel CIDR route binding `nixpi`'s
private IP into the same tunnel `cloudflared-connector` runs (Cloudflare
dashboard: Networking → Routes → Create route → Tunnel CIDR) — this is a
property of the tunnel object, not declared in the terranix module. Live
docs suggest a distinct target IP/VNet is expected even if a public-hostname
ingress already exists for the tunnel — verify before relying on reuse.

## 2. Generate the SSH CA and capture its public key (one-time, not terranix)

Dashboard: Zero Trust → Access controls → Service credentials → SSH →
**Generate SSH CA** → select **SSH with Access for Infrastructure** → copy the
**CA public key**.

Or API (idempotent — `GET` the same endpoint if it already exists):

```bash
curl "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/access/gateway_ca" \
  --request POST \
  --header "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

Commit the result into `modules/nixos/cloudflare-ssh-ca.pub`, replacing the
placeholder line. Only the public key ever goes in git — the CA's private
material never leaves Cloudflare.

## 3. Host side (cross-reference — do not edit from this skill)

`modules/nixos/core.nix` declares `services.openssh-ca-trust`:

```nix
options.services.openssh-ca-trust = {
  enable = lib.mkEnableOption "...";           # nixpi: true
  caKeyFile = lib.mkOption { default = ../nixos/cloudflare-ssh-ca.pub; };
  removeStaticKey = lib.mkEnableOption "...";   # nixpi: false until verified
};
```

`hosts/nixpi.nix` sets `services.openssh-ca-trust.enable = true` and leaves
`removeStaticKey` at its default `false` until an end-to-end ZTIA login has
been verified (see `docs/tunnel-architecture-and-runbook.md` §9). Do not edit
`hosts/` or `modules/nixos/*.nix` from this skill — it is the CF-provisioning
+ client playbook.

## 4. macOS client — enroll WARP, no ProxyCommand needed

1. Install the Cloudflare One Client (WARP) and enroll it in the Zero Trust
   org.
2. Set it to **Traffic-and-DNS mode**; turn on the Gateway proxy for TCP.
3. Confirm the split-tunnel / route covers `nixpi`'s private IP.
4. Verify visibility: `warp-cli target list` (or the client UI).

Then just:

```bash
ssh ismail@<nixpi-private-ip>
```

No `~/.ssh/config` ProxyCommand is needed or declared for this path — WARP
transparently intercepts the TCP connection. (This repo's
`modules/shared/home.nix` does not declare a `cloudflared access ssh`
ProxyCommand today.)

Verify it actually went through Cloudflare:

```bash
ssh ismail@<nixpi-private-ip> 'echo $SSH_CONNECTION'
```

On the LAN, `ssh ismail@nixpi.local` (mDNS) remains the zero-cloud break-glass
path regardless of ZTIA status.

## Full runbook

See `docs/tunnel-architecture-and-runbook.md` §9 for the complete, ordered
rollout (apply → generate CA → commit pubkey → rebuild → verify → only then
remove the static key) and §11 for flags that need live verification
(Tunnel CIDR route reuse, WARP session duration, `extraConfig` ordering).
