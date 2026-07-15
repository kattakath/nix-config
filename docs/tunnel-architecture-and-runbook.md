# Cloudflare Tunnel + ZTIA SSH Architecture & Host Runbook

> **STATUS: cutover COMPLETE on `nixpi` (2026-07-08).** `hosts/nixpi.nix` sets
> `services.openssh-ca-trust.enable = true` **and** `removeStaticKey = true`, so
> network SSH is **cert-only** and the legacy static key is gone. The rollout
> steps below are retained as the design record + re-run/break-glass reference,
> not a pending to-do. (The former step-by-step `ztia-rollout-runbook.md` — the
> executed 2026-07-08 procedure — has been folded away; §9 below is the rollout
> order, and git history preserves the detailed one-time commands.)

This document describes the **Cloudflare Access for Infrastructure (ZTIA)**
SSH design for this repo's 3-host aarch64 fleet (`macos`, `nixpi`, `nixvm`).
It supersedes the prior "static SSH key over a loginless tunnel" model: `nixpi`
now authenticates SSH via **short-lived certificates** minted by Cloudflare's
hosted SSH CA, gated by an Access policy tied to the operator's identity,
delivered over a Cloudflare One Client (WARP) connection — not a static key
possession check.

Everything here is grounded in the repo files:

- `modules/nixos/cloudflared.nix` — the hardened systemd Tunnel connector unit (unchanged by this cutover)
- `modules/nixos/core.nix` — SSH, mDNS, firewall, and the new `services.openssh-ca-trust` option
- `modules/nixos/cloudflare-ssh-ca.pub` — the committed Cloudflare SSH CA public key (placeholder until first apply)
- `modules/nixos/caddy-proxy.nix` — the local reverse-proxy/router behind the tunnel
- `hosts/nixpi.nix` — the only host that enables the connector + Caddy + `openssh-ca-trust`
- `hosts/nixvm.nix` — the sandbox VM (no tunnel, no ZTIA, static key retained)
- `hosts/macos.nix` — the client Mac (no tunnel, no incoming traffic at all)
- `infra/cloudflare/nixpi-ssh.nix` — terranix: the ZTIA target/application/policy for `nixpi`
- `flake.nix` — the `terranix` input + `cf-ssh-apply`/`cf-ssh-destroy` apps
- `infra/cloudflare/nixpi-tunnel.nix` — terranix: the remotely-managed tunnel + ingress + proxied CNAME + connector-token output (`cf-tunnel-apply`; tunnel/DNS only, unaffected by ZTIA)

---

## 1. Model at a glance

**Cloudflare Tunnel (unchanged) + Access for Infrastructure (new) — one host,
`nixpi`.** `nixpi` still runs the hardened `cloudflared` connector as a
systemd service (`cloudflared tunnel run`, token from
`/etc/secrets/cloudflared-token`) — ZTIA does **not** replace the tunnel, it
adds an identity + certificate layer on top of the same tunnel connectivity.

What changed is **how SSH authenticates**:

| | Before (retired) | Now (ZTIA) |
|---|---|---|
| Client requirement | `cloudflared` CLI only | **Cloudflare One Client (WARP)**, enrolled in the Zero Trust org |
| SSH auth | static ed25519 key in `authorizedKeys` | short-lived certificate, minted per-session by Cloudflare's SSH CA |
| Identity check | none (tunnel = pure TCP carrier) | IdP login → Access policy → cert principal = allowed UNIX username |
| Revocation | rotate/delete the key file | disable the Access policy — no host touch needed |
| Command audit | none | optional HPKE-encrypted SSH command logs (Access controls → Service credentials → SSH) |

This is **method (b)** of the four current Cloudflare SSH patterns — see
`docs/cloudflare-one-evaluation.md` for the full method comparison and why the
prior "decline ZTIA" verdict was superseded (SSH CA generation is now a
one-click dashboard action and Infrastructure Access is confirmed available on
all Zero Trust plans).

### Still loginless at the connector layer

- **No `cloudflared tunnel login`**, no `cert.pem`, no interactive browser step
  for the *tunnel* itself — that part is exactly as before.
- **WARP enrollment replaces "no client-side identity at all"** — this is the
  one new hard client-side dependency.

---

## 2. Host roles: one target, one sandbox, one client

| Host | Platform | Role | Connector? | ZTIA SSH? | sshd? | Public ingress? |
|---|---|---|---|---|---|---|
| `nixpi` | aarch64-linux (Raspberry Pi 4) | **LIVE server / SSH target** | yes | **yes** | yes | yes (SSH + Caddy landing page) |
| `nixvm` | aarch64-linux (UTM/QEMU sandbox VM) | sandbox, no ingress | no | **no — static key retained** | yes (LAN/vmnet only) | no |
| `macos` | aarch64-darwin (MacBook) | **client only** | no | n/a (client, not target) | no | no |

### `nixpi` is the fleet's sole ZTIA target and only public-facing host

`nixpi` runs sshd (`services.openssh`, `modules/nixos/core.nix`), the
`cloudflared-connector` unit, **and** `services.openssh-ca-trust.enable = true`
(`hosts/nixpi.nix`) — wiring `TrustedUserCAKeys` to the committed
`modules/nixos/cloudflare-ssh-ca.pub`. It also runs `caddy-proxy`
(`modules/nixos/caddy-proxy.nix`), unrelated to SSH, serving the static
`kattakath.com` landing page.

### `nixvm` deliberately stays on the static key — NOT part of this cutover

`nixvm` (`hosts/nixvm.nix`) does **not** set `services.openssh-ca-trust.enable`
and keeps `removeStaticKey` at its default `false`, so it authenticates
exactly as before: the shared static ed25519 key from `core.nix`. It is a
sandbox VM reachable only on the LAN (vmnet-shared IP or mDNS) — deliberately
excluded from the ZTIA cutover so a sandbox misconfiguration can never lock out
the one host that actually needs the fallback. Its serial console
(`serial-getty@ttyAMA0`) and LAN access remain untouched.

### `macos` is a ZTIA client, not a target

`macos` (`hosts/macos.nix`) runs no connector, no sshd, and no tunnel. Its
involvement is entirely as the **enrolled client** reaching `nixpi`: it needs
the Cloudflare One Client (WARP) installed and enrolled — see §7.

---

## 3. The connector unit (unchanged)

`modules/nixos/cloudflared.nix` defines the opt-in
`services.cloudflared-connector` option and, when enabled, a single hardened
systemd service. **Nothing in this module changed for the ZTIA cutover** —
ZTIA layers Access + a CA on top of the same tunnel connectivity; see the
header comment in `infra/cloudflare/nixpi-ssh.nix` for why.

### Token handling — never in argv, never in the store

```nix
ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
EnvironmentFile = cfg.tokenFile;   # default: /etc/secrets/cloudflared-token
```

Unchanged from before — see `modules/nixos/cloudflared.nix:71-73`.

---

## 4. Caddy — behind the tunnel, not in front of it (unchanged)

`modules/nixos/caddy-proxy.nix` is unaffected by this cutover. See the module
header and `hosts/nixpi.nix` for the single `kattakath.com` vhost it serves.

---

## 5. Authentication: ZTIA short-lived certificates (SSH-only cutover)

`modules/nixos/core.nix` now declares an opt-in
`services.openssh-ca-trust` option:

```nix
options.services.openssh-ca-trust = {
  enable = lib.mkEnableOption "trust Cloudflare's SSH CA ...";
  caKeyFile = lib.mkOption {
    default = ../nixos/cloudflare-ssh-ca.pub;
    ...
  };
  removeStaticKey = lib.mkEnableOption "remove the shared static ed25519 ...";
};
```

When enabled (`nixpi` only), it wires:

```nix
services.openssh.extraConfig = ''
  TrustedUserCAKeys ${caCfg.caKeyFile}
'';
```

sshd then accepts a short-lived certificate whose **principal** (the allowed
UNIX login, set by the Access policy's `connection_rules.ssh.usernames`) is
matched against the local user automatically — **no
`AuthorizedPrincipalsFile`/`AuthorizedPrincipalsCommand` needed**. This
differs from the older, now-deprecated "self-hosted short-lived certificates"
flow, which Cloudflare's own docs flag as incompatible with the Gateway SSH
proxy — the CA used here is generated via the dedicated `gateway_ca` endpoint,
a distinct mechanism.

The static key (`users.users.${userName}.openssh.authorizedKeys.keys`) is
still present on **every** host by default — it is only dropped when a host
sets `services.openssh-ca-trust.removeStaticKey = true`. `nixpi` does **not**
set this yet (see §9, rollout order); `nixvm` never will.

**Verify live** (flagged as unconfirmed in the underlying research): whether
NixOS's append-after-`settings` rendering of `extraConfig` still authenticates
correctly with `TrustedUserCAKeys` — there is no competing
`AuthorizedKeys*`/`AuthorizedPrincipals*` override here, so it is expected to
work, but confirm end-to-end on `nixpi` before flipping `removeStaticKey`.

---

## 6. Two names for `nixpi` (tunnel path unchanged; ZTIA path is different)

`nixpi` is reachable multiple ways depending on which layer you're using:

1. **`nixpi.local`** — mDNS (avahi), unchanged. LAN + break-glass path, works
   with no Cloudflare involvement at all, and still authenticates with
   whichever key/cert path sshd currently trusts (static key today; ZTIA cert
   too, once `TrustedUserCAKeys` is live — the CA doesn't care how you routed
   to the host).

2. **The Cloudflare Tunnel's public hostname** (if one is still configured for
   plain client-side `cloudflared access ssh`) — this is **method (a)**, the
   legacy pattern, and is no longer the primary path once ZTIA is live. It can
   coexist during migration but is not the target end state.

3. **ZTIA path (target end state):** no public hostname or port at all. The
   Cloudflare One Client (WARP), enrolled and running in Traffic-and-DNS mode,
   intercepts a plain `ssh ismail@<nixpi-private-ip>` connection to the IP
   declared as the Infrastructure Access **target**
   (`infra/cloudflare/nixpi-ssh.nix`), routed through a Tunnel CIDR route bound
   to the same connector. **Live-verify**: whether the existing tunnel ingress
   can double as this route, or whether a distinct private route must be
   added (the ZTIA docs model targets by IP + virtual network, which suggests
   the latter — see the flags list in §11).

---

## 7. Client side (`macos`) — WARP replaces the ProxyCommand

For the ZTIA path, `macos` needs:

1. **Cloudflare One Client (WARP)** installed, enrolled in the Zero Trust org,
   running in **Traffic-and-DNS mode** with the Gateway TCP proxy turned on,
   and a split-tunnel entry covering `nixpi`'s private IP/CIDR.
2. **No `~/.ssh/config` ProxyCommand at all** for `nixpi` once WARP is active
   — plain `ssh ismail@<nixpi-private-ip>` is transparently intercepted.
   `modules/shared/home.nix` does not declare a `cloudflared access ssh`
   ProxyCommand today (this repo's greenfield rewrite never wired one back
   in); no client-side Nix change is needed to adopt ZTIA.

Verify device/target visibility with `warp-cli target list` (or the
equivalent Cloudflare One Client UI) before attempting the first ZTIA login.

Ad-hoc verification once WARP is enrolled and the route is live:

```bash
ssh ismail@<nixpi-private-ip> 'echo $SSH_CONNECTION'
```

On the LAN, `ssh ismail@nixpi.local` continues to work as the zero-cloud
break-glass path regardless of ZTIA status.

---

## 8. Secret / trust model

- **`secrets/cloudflared-token.age`** (agenix) — committed encrypted to `nixpi`'s
  SSH host key + the operator key (`secrets/secrets.nix`), decrypted at activation
  to `/run/agenix/cloudflared-token`; `hosts/nixpi.nix` points
  `services.cloudflared-connector.tokenFile` there. (`/etc/secrets/cloudflared-token`
  is only the module default for hosts that don't opt into agenix — not `nixpi`.)
- **The Cloudflare SSH CA's private key never leaves Cloudflare.** Only its
  **public** key round-trips into this repo, committed at
  `modules/nixos/cloudflare-ssh-ca.pub` — safe to commit (a CA public key
  grants no access by itself; it only lets sshd verify certs Cloudflare
  signs). The file ships with a clear placeholder line until the real CA is
  generated and its public key captured (§9, step 2).
- **The Access policy, not a file on disk, is the revocation lever.** Disabling
  or editing `infra/cloudflare/nixpi-ssh.nix`'s policy and re-applying is how
  you cut someone off — no host rebuild needed.

---

## 9. RUNBOOK — ZTIA rollout order (read before touching anything)

**Do these in order. Do not skip to step 6 (static-key removal) before step 5
(verified login) — that is the lockout risk this runbook exists to prevent.**

1. **Terranix apply — create the CF-side objects** (target, Infrastructure
   Access application, Access policy):
   ```bash
   CLOUDFLARE_API_TOKEN=<scoped token> nix run .#cf-ssh-apply
   ```
   Token scope: **Account Zero Trust:Edit** (covers Access apps/policies and
   Infrastructure targets). This does **not** create the SSH CA — see next
   step.

   **Before this step matters:** `infra/cloudflare/nixpi-ssh.nix` currently
   has PLACEHOLDER values for `targetIp` and `virtualNetworkId` — fill in
   `nixpi`'s real routed private IP and virtual network ID first (see the
   live-verify flag in §6.3 about whether a distinct Tunnel CIDR route is
   needed).

2. **Generate the SSH CA and capture its public key** (one-time, dashboard or
   API — there is no Terraform resource for this):
   - Dashboard: Zero Trust → Access controls → Service credentials → SSH →
     **Generate SSH CA** → select **SSH with Access for Infrastructure** →
     copy the **CA public key**.
   - Or API: `POST /accounts/$ACCOUNT_ID/access/gateway_ca` (idempotent — if
     it already exists, `GET` the same endpoint instead).

3. **Commit the CA public key**, replacing the placeholder:
   ```bash
   # Edit modules/nixos/cloudflare-ssh-ca.pub — replace the placeholder
   # ssh-rsa line with the real CA public key copied in step 2.
   git add modules/nixos/cloudflare-ssh-ca.pub
   ```

4. **Rebuild `nixpi`** (this activates `TrustedUserCAKeys` — the static key
   stays in place too, since `removeStaticKey` is still `false`):
   ```bash
   ssh ismail@nixpi.local 'sudo nixos-rebuild switch --flake github:kattakath/nix-config#nixpi'
   ```

5. **Enroll a client and verify ZTIA login end-to-end** — install the
   Cloudflare One Client (WARP) on `macos`, enroll it in the Zero Trust org,
   confirm the target is visible (`warp-cli target list` or UI), then:
   ```bash
   ssh ismail@<nixpi-private-ip>
   ```
   Confirm this succeeds **without** using the static key (e.g. temporarily
   remove `~/.ssh/id_ed25519` from the agent, or watch `journalctl -u sshd` on
   `nixpi` for a certificate-based accept line) before proceeding.

6. **Only then**, flip the static key off:
   ```nix
   # hosts/nixpi.nix
   services.openssh-ca-trust.removeStaticKey = true;
   ```
   Rebuild again. From this point, `nixpi`'s network SSH is ZTIA-cert-only.
   **Physical console (getty) is never affected by this option** — it remains
   the hardware break-glass path if ZTIA and mDNS both become unreachable.

---

## 10. Day-in-the-life (steady state, post-cutover)

- **Reach `nixpi` from anywhere enrolled:** `ssh ismail@<nixpi-private-ip>`
  via WARP — no ProxyCommand, no prompt beyond the IdP session Cloudflare
  already holds.
- **On the LAN:** `ssh ismail@nixpi.local` skips Cloudflare entirely (mDNS) —
  authenticates via whatever sshd currently trusts (cert-only, post step 6).
- **Revoke access:** disable/edit the Access policy in
  `infra/cloudflare/nixpi-ssh.nix` and re-apply — no host touch.
- **Boot / reboot:** the connector auto-starts exactly as before; ZTIA needs
  nothing at boot beyond the already-rebuilt `TrustedUserCAKeys` config.

### What you never do

- **Never** commit the CA's private key — it never leaves Cloudflare; only the
  public half goes in `modules/nixos/cloudflare-ssh-ca.pub`.
- **Never** flip `removeStaticKey` before completing step 5 above.
- **Never** touch `nixvm`'s SSH config as part of this cutover — it is
  explicitly out of scope, kept as a key-based sandbox.
- **Never** put a Cloudflare API token in Nix, git, or argv — `cf-ssh-apply`/
  `cf-ssh-destroy` read `CLOUDFLARE_API_TOKEN` from the environment only.

---

## 11. Flags requiring live verification before/while implementing

(Carried forward from the underlying ZTIA research — re-check before/while
executing the runbook in §9.)

- Whether `nixpi`'s existing tunnel ingress can double as the ZTIA target's
  connectivity, or whether a **distinct private Tunnel CIDR route** must be
  added (Networking → Routes → Create route → Tunnel CIDR) — the docs model
  targets by IP + virtual network, suggesting the latter.
- Exact WARP session-duration/re-auth cadence for SSH (docs state a ~10-hour
  max session; the exact configurable field wasn't fully confirmed).
- NixOS's `extraConfig`-appends-last rendering of `TrustedUserCAKeys` — very
  likely fine given no conflicting directives, but confirmed only by a live
  test on `nixpi` (§9 step 5).
- Command-log **Logpush export to SIEM/S3 is Enterprise-only**; the
  downloadable HPKE-encrypted log via dashboard is available on all plans —
  fine for a solo operator, just no automatic export.
- No Terraform resource exists for the SSH CA itself (`gateway_ca`) — confirmed
  absent from the current provider docs; step 2 of the runbook is
  dashboard/API-only by necessity, not an oversight in
  `infra/cloudflare/nixpi-ssh.nix`.

---

## 12. Wiring reference

| Concern | File |
|---|---|
| Connector option + unit + hardening (unchanged) | `modules/nixos/cloudflared.nix` |
| Local reverse-proxy/router (behind the tunnel, unchanged) | `modules/nixos/caddy-proxy.nix` |
| sshd baseline + `openssh-ca-trust` option (`TrustedUserCAKeys`, `removeStaticKey`) | `modules/nixos/core.nix` |
| Committed Cloudflare SSH CA public key (placeholder until step 2/3 of §9) | `modules/nixos/cloudflare-ssh-ca.pub` |
| `nixpi` enables the connector + Caddy + ZTIA trust | `hosts/nixpi.nix` |
| `nixvm` — no tunnel, no ZTIA, static key retained (sandbox) | `hosts/nixvm.nix` |
| `macos` — ZTIA client (WARP), no server modules | `hosts/macos.nix` |
| Cloudflare-side ZTIA objects (target/application/policy) | `infra/cloudflare/nixpi-ssh.nix` |
| terranix input + `cf-ssh-apply`/`cf-ssh-destroy` apps | `flake.nix` |
| Tunnel token (agenix) | `secrets/cloudflared-token.age` → `/run/agenix/cloudflared-token` on `nixpi` |
| Tunnel + ingress + DNS provisioning (terranix, `cf-tunnel-apply`; unaffected by ZTIA) | `infra/cloudflare/nixpi-tunnel.nix` |
### Related skills

- `cloudflare-one` — general Cloudflare One / ZTIA guidance this doc draws on.
- `cloudflared-tunnel` — the ZTIA SSH setup playbook for `nixpi` itself (CA provisioning, terranix apply, host-side wiring, WARP client enrollment); this doc is its authoritative cross-reference for the full rollout order.
- `nixos-flake-install` / `nixvm-qemu-provision` — bring up `nixvm` itself (unaffected by this cutover).
