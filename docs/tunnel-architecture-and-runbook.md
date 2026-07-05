# Cloudflare Tunnel Architecture & Host Runbook

This document describes the **finalized, currently-on-`main`** loginless Cloudflare
Tunnel design for this repo. It is the authoritative reference for how NixOS hosts
reach the world over a tunnel, how the connector token is provisioned per host, and
the exact steps to bring a new host online.

Everything here is grounded in the repo files:

- `modules/nixos/cloudflared.nix` — the hardened systemd connector unit
- `modules/nixos/core.nix` — SSH, mDNS, firewall, agenix host identity
- `hosts/nixarm.nix`, `hosts/nixrpi.nix`, `hosts/nixamd.nix` — per-host tunnel secrets
- `hosts/nixcon.nix`, `hosts/nixtel.nix` — the Macs (clients only)
- `modules/shared/home.nix` — the client-side SSH `ProxyCommand`
- `secrets/secrets.nix` — the agenix recipient model
- `flake.nix` — how the modules are wired into every NixOS host

---

## 1. Model at a glance

**Remotely-managed (token) Cloudflare Tunnels.** Each NixOS host runs a hardened
`cloudflared` connector as a systemd service that executes `cloudflared tunnel run`
with a `TUNNEL_TOKEN` supplied from an agenix-decrypted `EnvironmentFile`. The tunnel
definition, its public-hostname ingress, and the proxied DNS record all live in the
**Cloudflare account** — provisioned once by `scripts/cf-one-provision.sh` via the
Cloudflare API — **not** in this repo.

This is deliberately **not** the upstream `services.cloudflared` NixOS module. That
module only drives *locally*-managed tunnels: it wants a credentials JSON plus an
in-repo `ingress` block and runs `cloudflared tunnel run <uuid>`. It has **no token
support**. Since this repo uses remotely-managed (token) tunnels so every connector
comes up at boot with zero interactive login (no `cloudflared tunnel login`, no
`cert.pem`), we run our own unit instead. See the header comment in
`modules/nixos/cloudflared.nix:1-21`.

### Loginless, everywhere

- **No `cloudflared tunnel login`**, no `cert.pem`, no interactive browser step on any host.
- **No WARP client**, no IdP, no Cloudflare Access policy in front of the SSH endpoint.
- Authentication to a host is **static SSH keys only**.

The connector token is the *only* secret a host needs, and it never touches the tunnel
login flow.

---

## 2. Host roles: targets vs. clients

| Host | Platform | Role | Connector? | sshd? |
|---|---|---|---|---|
| `nixarm` | aarch64-linux (UTM/QEMU VM) | **SSH target** | yes | yes |
| `nixrpi` | aarch64-linux (Raspberry Pi 4) | **SSH target** | yes | yes |
| `nixamd` | x86_64-linux (config-only / future hardware) | **SSH target** (inert today) | gated off | yes |
| `nixcon` | aarch64-darwin (Apple Silicon Mac) | **client only** | no | no |
| `nixtel` | x86_64-darwin (Apple Intel Mac) | **client only** | no | no |

### The NixOS hosts are the SSH *targets*

`nixarm`, `nixrpi`, and `nixamd` are the machines you reach *into*. Each runs sshd
(`services.openssh`, `modules/nixos/core.nix:25-35`) and, when it has a provisioned
token, the `cloudflared-connector` unit that carries its SSH port out over the tunnel.

### The Macs are *clients only*

`nixcon` and `nixtel` run **no connector, no sshd, and no tunnel**. The old
darwin cloudflared module was removed — there is no cloudflared system service on
macOS in this repo. The Macs' only involvement is *outbound*: they use `cloudflared
access ssh` as an SSH `ProxyCommand` to reach the NixOS targets (see §6). Their host
profiles (`hosts/nixcon.nix`, `hosts/nixtel.nix`) import only the shared darwin core
and Home Manager — no tunnel wiring at all.

---

## 3. The connector unit

`modules/nixos/cloudflared.nix` defines a single hardened systemd service,
`cloudflared-connector`, and is imported for **all** NixOS hosts globally via
`flake.nix:158` (`mkNixos` module list).

### Guarded activation

The unit only exists when the host declares its own token secret:

```nix
tokenSecretName = "${config.networking.hostName}-tunnel-token";
haveToken = lib.hasAttr tokenSecretName config.age.secrets;
in
{ config = lib.mkIf haveToken { systemd.services.cloudflared-connector = { … }; }; }
```

(`modules/nixos/cloudflared.nix:28-36`). A host without an
`age.secrets."<host>-tunnel-token"` entry (e.g. an unprovisioned `nixamd`) gets **no
service** and never fails activation on a missing token file. The module is a safe
no-op there.

### Token handling — never in argv, never in the store

```nix
ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
EnvironmentFile = config.age.secrets.${tokenSecretName}.path;
```

(`modules/nixos/cloudflared.nix:46-48`). `cloudflared tunnel run` with **no** name or
UUID picks up `TUNNEL_TOKEN` from the environment for a remotely-managed tunnel. The
token arrives as a one-line `TUNNEL_TOKEN=…` file that agenix decrypts at boot with the
host SSH key — so it never appears on the command line (argv is world-readable via
`/proc`) nor in a world-readable `/nix/store` path.

### Hardening

The unit runs under `DynamicUser = true` with a full systemd sandbox
(`modules/nixos/cloudflared.nix:53-79`): `ProtectSystem = "strict"`, `ProtectHome`,
`NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`, `ProtectKernelTunables`/`Modules`/
`ControlGroups`, `RestrictNamespaces`/`Realtime`/`SUIDSGID`, `LockPersonality`,
`MemoryDenyWriteExecute`, `RestrictAddressFamilies = [ AF_INET AF_INET6 AF_UNIX ]`, a
`@system-service` `SystemCallFilter` (minus `@privileged`/`@resources`), and native-only
`SystemCallArchitectures`. It waits on `network-online.target` and restarts on failure.

---

## 4. Authentication: static SSH keys only

The SSH endpoint is reachable over the tunnel with **no Access/identity layer in
front**, so `modules/nixos/core.nix:25-35` locks sshd down to keys only:

```nix
services.openssh = {
  enable = true;
  settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };
};
```

The single authorized identity is the operator's ed25519 key, declared on
`users.users.ismail.openssh.authorizedKeys.keys` (`modules/nixos/core.nix:17-23`). This
is the same public key that serves as the personal agenix recipient (`userKeys` in
`secrets/secrets.nix`).

There is no password path, no root login, no WARP, no IdP, and no Access — the tunnel
carries the port; the SSH key is the entire authentication story.

---

## 5. Two names per host

Every tunnelled host is reachable two ways:

1. **`<host>.local`** — mDNS, published by `services.avahi`
   (`modules/nixos/core.nix:44-52`, with `nssmdns4 = true` and address/workstation
   publishing; UDP 5353 is opened in the firewall at `core.nix:40`). This is the **LAN
   path and the break-glass path** — it works on the local network with no tunnel and
   no Cloudflare involvement at all. It is how you first reach a freshly-booted host to
   rekey it (see §7).

2. **`<host>.kattakath.com`** — a proxied CNAME that rides the Cloudflare tunnel,
   reachable from **anywhere**. Cloudflare forwards it to the connector, which forwards
   to `localhost:22` on the host. The public-hostname ingress and DNS record are
   provisioned in the Cloudflare account by `scripts/cf-one-provision.sh` (see the
   per-host header comments, e.g. `hosts/nixarm.nix:49-55`).

The firewall opens only TCP 22 and UDP 5353 (`modules/nixos/core.nix:37-41`). The
public hostname has **no Access policy** in front of it, so auth over the tunnel is SSH
key only — matching the `.local` LAN path.

---

## 6. Client side (the Macs)

The outbound SSH config lives in `modules/shared/home.nix:87-125`, gated to darwin
(`lib.mkIf pkgs.stdenv.isDarwin`). One wildcard block covers every tunnelled host:

```nix
"*.kattakath.com" = {
  User = config.home.username;              # ismail
  IdentityFile = "~/.ssh/id_ed25519";
  ProxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
};
```

`ssh nixarm.kattakath.com` transparently routes through `cloudflared access ssh` —
there is no public SSH port; the tunnel forwards to the host's `localhost:22`. No WARP,
no interactive login: the public hostname has no Access policy, so the connection
succeeds on the SSH key alone. One block covers `nixarm`/`nixrpi`/`nixamd` (and would
cover the Macs if they were ever targets) with no per-host duplication.

On the LAN you can skip the tunnel entirely and `ssh ismail@<host>.local`.

---

## 7. Secret model per host

Every host's connector token is `secrets/<host>-tunnel-token.age`, an agenix file
containing one line `TUNNEL_TOKEN=…` (a host may also declare *other* host-scoped
secrets alongside it — e.g. `nixarm` adds `secrets/nixarm-github-runner-token.age` —
and every one must be rekeyed to the host key together, see §8 step 3). agenix decrypts it at activation using the host's
SSH host key — `age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`
(`modules/nixos/core.nix:74`). The recipient set of each `.age`
(`secrets/secrets.nix`) is what differs per host, and it drives the provisioning path.

> **Hazard (applies to every host):** the SSH host key *is* the age decryption
> identity. Rotating, reinstalling, or reimaging `/etc/ssh/ssh_host_ed25519_key`
> silently breaks decryption of every host-scoped `.age` at the next activation. Re-run
> the `agenix-host-rekey` skill after any host-key change. (See `modules/nixos/core.nix:66-73`
> and the per-host header comments.)

### Uniform model — personal-key-only, post-boot rekey (all three hosts)

All three NixOS hosts (`nixarm`, `nixrpi`, `nixamd`) follow the **same** flow: NO
prebake, NO pinned host key baked into any image. Each host's image is generic and
generates its own `/etc/ssh` host key at first boot. Pre-first-boot, each token is
encrypted to the **personal key only**:

```nix
"nixarm-tunnel-token.age".publicKeys = userKeys;
"nixrpi-tunnel-token.age".publicKeys = userKeys;
"nixamd-tunnel-token.age".publicKeys = userKeys;
```

Wired in `hosts/nixarm.nix:77`, `hosts/nixrpi.nix:52`, and (gated) `hosts/nixamd.nix`.
After a host's first boot you add its own `/etc/ssh/ssh_host_ed25519_key.pub` as a
recipient and re-encrypt via the `agenix-host-rekey` skill (the runbook in §8). Each
host's first-boot key is a unique per-host identity, so no key pinning or injection is
ever needed.

### `nixamd` — reserved but inert (still the same flow)

`nixamd` is config-only today (no real hardware; x86_64 under TCG on Apple Silicon is
too slow to boot locally — `hosts/nixamd.nix:1-6`). Its CF tunnel + DNS are reserved and
`secrets/nixamd-tunnel-token.age` exists encrypted to the personal key only:

```nix
"nixamd-tunnel-token.age".publicKeys = userKeys;
```

But `nixamd` has no provisioned host key, so it could not decrypt that token. The host
therefore gates the secret behind a `tunnelReady` flag (default `false`,
`hosts/nixamd.nix:25-31, 74-76`):

```nix
age.secrets = lib.mkIf tunnelReady {
  "nixamd-tunnel-token".file = "${secretsDir}/nixamd-tunnel-token.age";
};
```

While `tunnelReady = false`, the secret is undeclared, so the guard in
`modules/nixos/cloudflared.nix` leaves the connector unit off — and eval never breaks on
the reserved `.age`. Flip it to `true` only after the host key is added as a recipient
and the token re-encrypted.

### Provisioning the tunnel (all hosts)

The Cloudflare-side objects — the tunnel, its public-hostname ingress
(`<host>.kattakath.com` → `ssh://localhost:22`), the proxied CNAME, and the connector
token itself — are created once by **`scripts/cf-one-provision.sh`** against the
Cloudflare API. This uses **no `cloudflared login`** and produces the token you encrypt
into `<host>-tunnel-token.age`.

---

## 8. RUNBOOK — bringing a host online

One identical runbook covers **all three** NixOS hosts (`nixarm`, `nixrpi`, `nixamd`).
Each ships with a personal-key-only token that the host itself **cannot** decrypt until
its own first-boot host key is added as a recipient. The sequence:

1. **Install + Boot.** For a fresh disk, disko handles partitioning declaratively before
   `nixos-install` — one command replaces manual `parted`/`mkfs`/`mount` (see **nixos-flake-install**
   skill § 2). On the LAN the host publishes `<host>.local` via avahi; the `nixarm` QEMU VM also
   forwards SSH to `localhost:2222` (see the `nixarm-vm` skill).

2. **SSH in with the personal key** (the break-glass path — no tunnel yet):
   ```bash
   ssh ismail@nixarm.local        # or nixrpi.local / nixamd.local
   ssh -p 2222 ismail@localhost   # nixarm QEMU VM alternative
   ```

   > **Reprovision gotcha (stale host key):** a fresh host generates a NEW
   > `/etc/ssh/ssh_host_ed25519_key` at first boot, but it reuses the same
   > `<host>.local` mDNS name (and, for the VM, `[localhost]:2222`). If a prior
   > host by that name is still cached in your Mac's `~/.ssh/known_hosts`, SSH
   > aborts with `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!` /
   > `Host key verification failed.` — this is expected on every reprovision, not
   > an attack. Clear the stale entry, then reconnect:
   > ```bash
   > ssh-keygen -R nixarm.local            # or nixrpi.local / nixamd.local
   > ssh-keygen -R '[localhost]:2222'      # nixarm QEMU VM alternative
   > ssh ismail@nixarm.local               # re-accepts the new host key
   > ```
   > Old hosts may leave BOTH an `ssh-ed25519` and a legacy `ssh-rsa` line —
   > `ssh-keygen -R` removes every entry for the name in one shot.

3. **Rekey** — add the host's own `/etc/ssh/ssh_host_ed25519_key.pub` as a recipient in
   `secrets/secrets.nix` and re-encrypt `<host>-tunnel-token.age` to include it. Use the
   **`agenix-host-rekey`** skill, which automates collecting the key and re-encrypting.
   For `nixamd`, also flip `tunnelReady = true` in `hosts/nixamd.nix`.

   > **Rekey ALL host-scoped secrets, not just the tunnel token.** agenix activates
   > secrets as a single batch (`agenixInstall`). If *any* host-scoped `.age` for this
   > host is still personal-key-only — not yet rekeyed to the live host key — the whole
   > batch aborts at activation with `no identity matched any of the recipients`, and
   > `nixos-rebuild switch` returns non-zero, **even if the tunnel token itself decrypts
   > fine**. So rekey *every* host-scoped `.age` for the host to the live host key in the
   > SAME pass. `nixarm`, for example, declares two: `secrets/nixarm-tunnel-token.age`
   > **and** `secrets/nixarm-github-runner-token.age` — both must include the host key or
   > activation fails. (Verified 2026-07-04: the runner token blocked activation until it
   > too was rekeyed; fixed in commit 718c654.)

4. **Stage the changed files** — flakes evaluate the git tree, not the working
   directory, so the re-encrypted `.age` (and any `.nix` edits) **must** be staged:
   ```bash
   git add -A
   ```

5. **Rebuild** to activate the connector with the now-decryptable token:
   ```bash
   nixos-rebuild switch --flake .#nixarm     # or .#nixrpi / .#nixamd
   ```

6. **Verify:**
   ```bash
   systemctl is-active cloudflared-connector   # → active
   ```
   Then confirm the tunnel path from a client: `ssh nixarm.kattakath.com`.

#### Build on the host for `nixamd` (x86_64)

`nixamd` is `x86_64-linux`. Do **not** try to build/activate it from an Apple Silicon
Mac — x86_64 runs under slow TCG emulation there. Run `nixos-rebuild switch` **on the
`nixamd` machine itself** (step 5), which is why the runbook has you SSH in first.

#### Ordering gotcha: rekey **before** rebuild

The re-encryption in step 3 must land **before** the `nixos-rebuild switch` in step 5.
If you rebuild first, the host key is not yet a recipient, agenix cannot decrypt the
token at activation, and the connector fails to start (typically a
`243/CREDENTIALS`-class failure). Always: **rekey → `git add` → rebuild → verify.**

---

## 9. Day-in-the-life (steady state)

Once a host is online, there is nothing to babysit:

- **Reach it from anywhere:** `ssh nixarm.kattakath.com`. SSH silently runs
  `cloudflared access ssh --hostname %h` as its `ProxyCommand`
  (`modules/shared/home.nix:119-123`); the tunnel forwards to the host's
  `localhost:22`. No public port, no prompt.
- **On the LAN:** `ssh ismail@nixarm.local` skips the tunnel entirely (mDNS).
- **Boot / reboot:** the connector is `wantedBy = multi-user.target`
  (`modules/nixos/cloudflared.nix:41`) and auto-starts. A reboot needs **nothing** —
  the token decrypts from the host key and the tunnel re-registers on its own.

### What you never do

- **Never** run `cloudflared tunnel login` or manage a `cert.pem` — this is a
  remotely-managed (token) tunnel; there is no origin-cert login flow.
- **Never** install WARP, an IdP, or a Cloudflare Access policy in front of SSH — auth
  is the SSH key, full stop.
- **Never** perform an interactive login at boot or when SSHing — both the connector
  (host side) and `cloudflared access ssh` (client side) are fully non-interactive.
- **Never** put a token in argv or in Nix/the store — it is only ever an agenix
  `EnvironmentFile`.

---

## 9a. Sibling path — HTTP ingress + Access (the LiteLLM container)

Everything above describes the **per-host SSH connector** model: one tunnel per
NixOS host, `ssh://localhost:22` ingress, **no Access** (auth is the SSH key). The
repo also ships a *different* tunnel shape for a containerized HTTP service — the
LiteLLM proxy — and it is worth calling out how it diverges, so the two are not
conflated.

| Aspect | Per-host SSH (this doc, §1–9) | LiteLLM container (`deploy/litellm/`) |
|---|---|---|
| Tunnel | one per host (`nixarm`, …) | **one dedicated** tunnel named `litellm` |
| Ingress `service` | `ssh://localhost:22` | `http://litellm:4000` (**docker-DNS name**, not localhost) |
| Where the connector runs | NixOS `cloudflared-connector` systemd unit | a `cloudflared` **container** beside the app + a `postgres` container (compose) |
| Token secret | agenix `<host>-tunnel-token.age` (host-key scoped) | `TUNNEL_TOKEN` in `deploy/litellm/.env` (gitignored) |
| Identity layer | **none** — SSH key only | **Cloudflare Access** (allow `kattakath.com` email-domain + service-token policy) |
| App auth | SSH key | humans: LiteLLM **Google SSO** (`/sso/callback`); API clients: **virtual keys** (master key stays server-only) |
| Public name | `<host>.kattakath.com` | `litellm.kattakath.com` |
| Provisioner | `scripts/cf-one-provision.sh` | `infra/cloudflare/litellm.nix` (terranix) via `nix run .#cf-litellm-apply` (OpenTofu) |
| Compose file | n/a (systemd unit) | Nix-rendered from `packages/litellm-compose.nix` |

Two points make the HTTP path genuinely different from the SSH path:

1. **The ingress URL is a docker-DNS name, not `localhost`.** The connector runs
   in a container sharing an internal network with the litellm container, so the
   account-side ingress `service` is `http://litellm:4000` (the compose service
   name), resolved inside the connector's own namespace — whereas the SSH
   connector runs on the host and points at the host's `localhost:22`.

2. **Access sits in front, and Google SSO runs behind it.** The SSH endpoints
   deliberately have *no* Access policy (§5, §9 "What you never do"). The LiteLLM
   app deliberately *does*: a self-hosted Access application with an **allow**
   policy scoped to the `kattakath.com` **email domain** and a **non_identity**
   (service-token) policy. Humans clear Access with Google, then complete
   LiteLLM's own Google SSO — the Google→`/sso/callback` redirect survives Access
   precisely because the browser is already an allowed `@kattakath.com` identity
   (a domain-allow policy, *not* a `/sso/*` bypass, which would open an
   unauthenticated hole). API clients pass Access via `CF-Access-Client-Id` /
   `CF-Access-Client-Secret` and then present a **virtual key** to the proxy; the
   master key is never distributed. The Admin UI, virtual keys and SSO user table
   need a database, so the compose stack also runs a `postgres` container
   (internal-only, named volume). This does not change the SSH model — it is a
   separate application object in the same Cloudflare account.

Full runbook, compose file, and client call examples live in
[`deploy/litellm/README.md`](../deploy/litellm/README.md). The account-side
provisioning is the terranix module `infra/cloudflare/litellm.nix`, applied with
`nix run .#cf-litellm-apply` (OpenTofu; needs a live `CLOUDFLARE_API_TOKEN`) and
torn down with `nix run .#cf-litellm-destroy`; the compose file is Nix-rendered
from `packages/litellm-compose.nix`.

---

## 10. Wiring reference

| Concern | File:line |
|---|---|
| Connector unit + guard + hardening | `modules/nixos/cloudflared.nix` |
| Module imported for every NixOS host | `flake.nix:158` |
| sshd keys-only, no root/password | `modules/nixos/core.nix:25-35` |
| Authorized SSH key (`ismail`) | `modules/nixos/core.nix:20-22` |
| mDNS `<host>.local` (avahi) + UDP 5353 | `modules/nixos/core.nix:40, 44-52` |
| agenix host identity (host SSH key) | `modules/nixos/core.nix:74` |
| `nixarm` token (personal key only) | `hosts/nixarm.nix:77`; `secrets/secrets.nix` |
| `nixrpi` token (personal key only) | `hosts/nixrpi.nix:52`; `secrets/secrets.nix` |
| `nixamd` token (gated `tunnelReady`) | `hosts/nixamd.nix:30, 74-76`; `secrets/secrets.nix` |
| Client `ProxyCommand` (`*.kattakath.com`) | `modules/shared/home.nix:119-123` |
| Macs are clients (no tunnel/sshd) | `hosts/nixcon.nix`, `hosts/nixtel.nix` |

### Related skills

- `agenix-host-rekey` — re-encrypt a host-scoped secret to the host's SSH key after first boot (the uniform post-boot step for all three NixOS hosts).
- `cloudflared-tunnel` — client-side setup + `scripts/cf-one-provision.sh` (token provisioning).
- `nixarm-vm` / `utm-vm-provision` / `nixos-flake-install` — bring up the VM/host itself.
