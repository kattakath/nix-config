---
name: cloudflared-tunnel
description: >
  Set up the Cloudflare Tunnel CLIENT path on macOS — create a named tunnel with `cloudflared`,
  route DNS to it, and reach a NixOS host over SSH via a ProxyCommand. Use when asked to "set up a
  cloudflare tunnel", "expose SSH over cloudflare", "reach a host over the tunnel", configure a
  "cloudflared proxycommand", or fix `cloudflared tunnel login` failing with API error 10000. Pairs
  with agenix-host-rekey (the host-side tunnel-creds secret) and the nixbox host profile.
---

# Cloudflare Tunnel (client + DNS + SSH ProxyCommand)

## Gotchas (read first)

- **`cloudflared tunnel login` API error 10000** = a stale/short `~/.cloudflared/cert.pem`. A healthy
  cert is multi-KB; a corrupt one is often **~266 B**. Back it up and re-login (step 1).
- **Direct port 22 is NOT reachable and that is expected.** `nixbox.kattakath.com` resolves to a
  Cloudflare edge IP (`172.64.x.x`), not the host. Traffic only flows through the tunnel — never
  diagnose the tunnel by `nc -z host 22` against the public name.
- **Verified-working signature:** once connected, `$SSH_CONNECTION` on the host shows `::1` —
  cloudflared terminates the tunnel and the SSH session arrives on the host as `localhost:22`.
- The NixOS side and the agenix host-key handoff live in sibling skills — don't re-derive them here.

## 1. Authenticate (writes ~/.cloudflared/cert.pem)

```bash
ls -l ~/.cloudflared/cert.pem 2>/dev/null      # healthy = multi-KB; ~266 B = corrupt
mv ~/.cloudflared/cert.pem ~/.cloudflared/cert.pem.bak 2>/dev/null || true   # only if stale
cloudflared tunnel login                       # opens browser → pick the kattakath.com zone
```

## 2. Create the tunnel (writes ~/.cloudflared/<UUID>.json credentials)

```bash
cloudflared tunnel create nixbox               # prints the tunnel UUID + creds path
cloudflared tunnel list                        # confirm name → UUID
```

The `~/.cloudflared/<UUID>.json` is the **credentialsFile** the host needs — it becomes the agenix
secret `nixbox-tunnel-creds.age` (encrypt + rekey via the **agenix-host-rekey** skill).

## 3. Route DNS (adds the CNAME on the zone)

```bash
cloudflared tunnel route dns nixbox nixbox.kattakath.com
dig +short nixbox.kattakath.com                # → a 172.64.x edge IP (NOT the host) — expected
```

## 4. NixOS host side (cross-reference)

`hosts/nixbox.nix` runs `services.cloudflared.tunnels."<UUID>"` with
`credentialsFile = config.age.secrets.tunnel-creds.path` and an ingress rule
`ssh://localhost:22`. The secret must be re-encrypted to the host's SSH host key before
`services.cloudflared` can decrypt it at activation — that is the **agenix-host-rekey** skill.
Do not edit `hosts/` or `*.nix` from this skill; it is the client/DNS playbook.

## 5. macOS client — reach the host via SSH ProxyCommand

Declarative (Home-Manager, in `modules/shared/home.nix`-style config):

```nix
programs.ssh.matchBlocks."nixbox.kattakath.com" = {
  user = "izzy";
  proxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
};
```

Ad-hoc test (no config change):

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" izzy@nixbox.kattakath.com
```

Verify it actually went through the tunnel:

```bash
ssh izzy@nixbox.kattakath.com 'echo $SSH_CONNECTION'    # → ::1 ...  (localhost = tunnel-terminated)
```

## Phase 2 (optional) — Cloudflare Access policy

Adding a Cloudflare **Access** application/policy on `nixbox.kattakath.com` puts an identity gate in
front of the SSH layer (defense-in-depth). This is a **Cloudflare dashboard step**, not a `cloudflared`
CLI action — configure it in the Zero Trust dashboard, then `cloudflared access ssh` will prompt for
the Access login before the SSH handshake.
