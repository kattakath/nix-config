# Cloudflare Tunnel Architecture & Host Runbook

This document describes the loginless Cloudflare Tunnel design for this repo's
3-host aarch64 fleet (`macos`, `nixpi`, `nixvm`). It is the authoritative
reference for how `nixpi` reaches the world over a tunnel, how the connector
token is provisioned, and the exact steps to bring it online.

Everything here is grounded in the repo files:

- `modules/nixos/cloudflared.nix` — the hardened systemd connector unit
- `modules/nixos/caddy-proxy.nix` — the local reverse-proxy/router behind the tunnel
- `modules/nixos/core.nix` — SSH, mDNS, firewall
- `hosts/nixpi.nix` — the only host that enables the connector + Caddy
- `hosts/nixvm.nix` — the sandbox VM (no tunnel, no public ingress)
- `hosts/macos.nix` — the client Mac (no tunnel, no incoming traffic at all)
- `scripts/cf-one-provision.sh` — Cloudflare-account-side provisioning
- `flake.nix` — how the modules are wired into the NixOS hosts

---

## 1. Model at a glance

**Remotely-managed (token) Cloudflare Tunnel — one host, `nixpi`.** `nixpi`
runs a hardened `cloudflared` connector as a systemd service that executes
`cloudflared tunnel run` with a `TUNNEL_TOKEN` supplied from
`/etc/secrets/cloudflared-token` via `EnvironmentFile`. The tunnel definition,
its public-hostname ingress, and the proxied DNS record all live in the
**Cloudflare account** — provisioned by `scripts/cf-one-provision.sh` via the
Cloudflare API — **not** in this repo.

This is deliberately **not** the upstream `services.cloudflared` NixOS module.
That module only drives *locally*-managed tunnels: it wants a credentials JSON
plus an in-repo `ingress` block and runs `cloudflared tunnel run <uuid>`. It
has **no token support**. Since this repo uses a remotely-managed (token)
tunnel so the connector comes up at boot with zero interactive login (no
`cloudflared tunnel login`, no `cert.pem`), we run our own unit instead. See
the header comment in `modules/nixos/cloudflared.nix:1-21`.

### Loginless

- **No `cloudflared tunnel login`**, no `cert.pem`, no interactive browser step.
- **No WARP client**, no IdP, no Cloudflare Access policy in front of SSH.
- Authentication to `nixpi` is **static SSH keys only**.

The connector token is the only secret the host needs, and it never touches
the tunnel login flow.

---

## 2. Host roles: one target, one sandbox, one client

| Host | Platform | Role | Connector? | sshd? | Public ingress? |
|---|---|---|---|---|---|
| `nixpi` | aarch64-linux (Raspberry Pi 4) | **LIVE server / SSH target** | yes | yes | yes (SSH + Caddy landing page) |
| `nixvm` | aarch64-linux (UTM/QEMU sandbox VM) | sandbox, no ingress | no | yes (LAN/vmnet only) | no |
| `macos` | aarch64-darwin (MacBook) | **client only** | no | no | no |

### `nixpi` is the fleet's sole SSH target and only public-facing host

`nixpi` runs sshd (`services.openssh`, `modules/nixos/core.nix:26-36`) and the
`cloudflared-connector` unit that carries its SSH port out over the tunnel. It
also runs `caddy-proxy` (`modules/nixos/caddy-proxy.nix`), a local
reverse-proxy sitting **behind** the same tunnel, currently serving only the
static `kattakath.com` landing page (`hosts/nixpi.nix:60-63`, content at
`packages/landing`).

### `nixvm` is a sandbox — no public ingress

`nixvm` (`hosts/nixvm.nix`) is a minimal UTM/QEMU VM: it boots, has a serial
console, and runs sshd — reachable only on the LAN (vmnet-shared IP or mDNS).
It imports neither `cloudflared.nix` nor `caddy-proxy.nix`. GUI / remote
desktop is explicitly deferred to a follow-up; today it is boot + SSH + disko
only.

### `macos` is a client only

`macos` (`hosts/macos.nix`) runs **no connector, no sshd, and no tunnel** — it
imports only `modules/darwin/core.nix` and Home Manager. Its only involvement
with the tunnel is *outbound*: reaching `nixpi` over SSH (see §6). There is no
server-side module wired into the darwin host profile at all.

---

## 3. The connector unit

`modules/nixos/cloudflared.nix` defines the opt-in
`services.cloudflared-connector` option and, when enabled, a single hardened
systemd service, `cloudflared-connector`. Only `nixpi` enables it
(`hosts/nixpi.nix:55`); `nixvm` and `macos` never import the module.

### Token handling — never in argv, never in the store

```nix
ExecStart = "${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel run";
EnvironmentFile = cfg.tokenFile;   # default: /etc/secrets/cloudflared-token
```

(`modules/nixos/cloudflared.nix:71-73`). `cloudflared tunnel run` with **no**
name or UUID picks up `TUNNEL_TOKEN` from the environment for a
remotely-managed tunnel. The token is a plain, operator-placed file — `/etc/secrets/cloudflared-token`,
containing one line `TUNNEL_TOKEN=…` — placed manually after provisioning and
**never committed to git**. There is no agenix, no sops, no encryption step in
this repo: system/service secrets are plain root-only files under
`/etc/secrets/`. A boot-time activation script warns (but does not abort) if
the file is missing (`modules/nixos/cloudflared.nix:54-60`); the unit itself
retries on failure (`Restart = "on-failure"`, `RestartSec = 5`), so dropping
the file in after first boot self-heals without a rebuild.

### Hardening

The unit runs under `DynamicUser = true` with a full systemd sandbox
(`modules/nixos/cloudflared.nix:78-104`): `ProtectSystem = "strict"`,
`ProtectHome`, `NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`,
`ProtectKernelTunables`/`Modules`/`ControlGroups`, `RestrictNamespaces`/
`Realtime`/`SUIDSGID`, `LockPersonality`, `MemoryDenyWriteExecute`,
`RestrictAddressFamilies = [ AF_INET AF_INET6 AF_UNIX ]`, a `@system-service`
`SystemCallFilter` (minus `@privileged`/`@resources`), and native-only
`SystemCallArchitectures`. It waits on `network-online.target`.

---

## 4. Caddy — behind the tunnel, not in front of it

`modules/nixos/caddy-proxy.nix` is a generic, opt-in local reverse-proxy/router
wrapping upstream `services.caddy`. The topology is **tunnel → Caddy →
service**: `cloudflared-connector` terminates the tunnel and forwards to Caddy
on loopback; Caddy then routes to the right local service by Host header
(`modules/nixos/caddy-proxy.nix:7-18`). This means no public IP or
port-forward is ever required, and Cloudflare Access could front any vhost
independently in the future without this module having an opinion about it.

Each `virtualHosts.<name>` entry is either `reverseProxyTo` (an upstream URL)
or `root` (a static-file directory) — never both (enforced by an assertion,
`modules/nixos/caddy-proxy.nix:64-69`). Today `nixpi` declares exactly one
vhost:

```nix
services.caddy-proxy = {
  enable = true;
  virtualHosts."kattakath.com".root = ../packages/landing;
};
```

(`hosts/nixpi.nix:60-63`) — the static `kattakath.com` landing page. Future
services front new `virtualHosts` entries on the same Caddy instance rather
than provisioning a new tunnel per service.

---

## 5. Authentication: static SSH keys only

The SSH endpoint is reachable over the tunnel with **no Access/identity layer
in front**, so `modules/nixos/core.nix:26-36` locks sshd down to keys only:

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
`users.users.${userName}.openssh.authorizedKeys.keys`
(`modules/nixos/core.nix:21-23`) — shared by every NixOS host (`nixpi` and
`nixvm` alike).

There is no password path, no root login, no WARP, no IdP, and no Access — the
tunnel carries the port; the SSH key is the entire authentication story.

---

## 6. Two names for `nixpi`

`nixpi` is reachable two ways:

1. **`nixpi.local`** — mDNS, published by `services.avahi`
   (`modules/nixos/core.nix:44-53`, with `nssmdns4 = true` and address/
   workstation publishing; UDP 5353 is opened in the firewall at
   `core.nix:41`). This is the **LAN path and the break-glass path** — it
   works with no tunnel and no Cloudflare involvement at all.

2. **`nixpi.kattakath.com`** — a proxied CNAME that rides the Cloudflare
   tunnel, reachable from **anywhere**. Cloudflare forwards it to the
   connector, which forwards to `localhost:22` on the host. The
   public-hostname ingress and DNS record are provisioned in the Cloudflare
   account by `scripts/cf-one-provision.sh`.

The firewall opens only TCP 22 and UDP 5353 by default
(`modules/nixos/core.nix:38-42`); `caddy-proxy` additionally opens TCP 80/443
when enabled (`modules/nixos/caddy-proxy.nix:99-102`). The public hostname has
**no Access policy** in front of it, so auth over the tunnel is SSH key only —
matching the `.local` LAN path.

`nixvm` has no public hostname at all — only its LAN/vmnet-shared IP or
`nixvm.local` (mDNS), same as any other host on `core.nix`.

---

## 7. Client side (`macos`)

`macos` is the only client. Home Manager's `modules/shared/home.nix` currently
declares an SSH `settings` block only for `*.local` (agent forwarding on for
interactive LAN admin work, `modules/shared/home.nix:117-125`with the shared
defaults at `:102-115`). There is **no `*.kattakath.com` ProxyCommand block
wired yet** — reaching `nixpi.kattakath.com` today means either an ad-hoc
`cloudflared access ssh` invocation or adding a `settings."nixpi.kattakath.com"`
block declaratively:

```nix
programs.ssh.settings."nixpi.kattakath.com" = {
  User = config.home.username;
  IdentityFile = "~/.ssh/id_ed25519";
  ProxyCommand = "${pkgs.cloudflared}/bin/cloudflared access ssh --hostname %h";
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

On the LAN you can skip the tunnel entirely and `ssh ismail@nixpi.local`.

---

## 8. Secret model

`/etc/secrets/cloudflared-token` on `nixpi` is a plain, root-only,
operator-placed file — never generated, encrypted, or committed by this repo.
This repo does **not** use agenix or sops (removed entirely; see
`memory/agenix-removed-etc-secrets.md` for the historical PR that dropped it —
gitignored, not part of this doc's authority). The convention is documented in
`CLAUDE.md`'s secrets model: system/service credentials live at
`/etc/secrets/<name>` on each host, placed manually after provisioning.

There is no host-key rekey step for `cloudflared-token` — it is not
identity-scoped to any key, just a plain file the host reads at boot. If the
Pi is ever reimaged, the runbook (§9) is simply: reprovision the tunnel, place
the new token file, rebuild.

### Provisioning the tunnel

The Cloudflare-side objects — the tunnel, its public-hostname ingress
(`nixpi.kattakath.com` → `ssh://localhost:22`), the proxied CNAME, and the
connector token itself — are created by **`scripts/cf-one-provision.sh`**
against the Cloudflare API. This uses **no `cloudflared login`** and produces
the token you place at `/etc/secrets/cloudflared-token`.

---

## 9. RUNBOOK — bringing `nixpi` online

1. **Install + Boot.** Flash `nixpi-installer-image`
   (`.#packages.aarch64-linux.nixpi-installer-image`) to an SD card, boot the
   Pi. On the LAN the host publishes `nixpi.local` via avahi.

2. **SSH in with the personal key** (the break-glass path — no tunnel yet):
   ```bash
   ssh ismail@nixpi.local
   ```

   > **Reprovision gotcha (stale host key):** a fresh Pi generates a NEW
   > `/etc/ssh/ssh_host_ed25519_key` at first boot, but it reuses the same
   > `nixpi.local` mDNS name. If a prior host by that name is still cached in
   > your Mac's `~/.ssh/known_hosts`, SSH aborts with `WARNING: REMOTE HOST
   > IDENTIFICATION HAS CHANGED!` — this is expected on every reprovision, not
   > an attack. Clear the stale entry, then reconnect:
   > ```bash
   > ssh-keygen -R nixpi.local
   > ssh ismail@nixpi.local               # re-accepts the new host key
   > ```

3. **Provision the tunnel + token** (Cloudflare account side):
   ```bash
   CF_API_TOKEN=<token-with-Tunnels:Edit+DNS:Edit> ./scripts/cf-one-provision.sh nixpi
   ```
   This prints a `TUNNEL_TOKEN=…` line to stdout — a secret, never written to
   a repo file.

4. **Place the token file on the host:**
   ```bash
   ssh ismail@nixpi.local 'sudo tee /etc/secrets/cloudflared-token >/dev/null' <<< "TUNNEL_TOKEN=<token>"
   ssh ismail@nixpi.local 'sudo chmod 600 /etc/secrets/cloudflared-token'
   ```

5. **Rebuild (if not already active) or just restart the unit** — the
   activation script only warns; the service itself retries once the file
   exists:
   ```bash
   ssh ismail@nixpi.local 'sudo systemctl restart cloudflared-connector'
   # or, if the module was just enabled for the first time:
   ssh ismail@nixpi.local 'sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixpi'
   ```

6. **Verify:**
   ```bash
   ssh ismail@nixpi.local 'systemctl is-active cloudflared-connector'   # → active
   ```
   Then confirm the tunnel path from a client: `ssh nixpi.kattakath.com` (or the ad-hoc
   `cloudflared access ssh` ProxyCommand from §7).

---

## 10. Day-in-the-life (steady state)

Once `nixpi` is online, there is nothing to babysit:

- **Reach it from anywhere:** `ssh nixpi.kattakath.com` (via a ProxyCommand —
  see §7). No public port, no prompt.
- **On the LAN:** `ssh ismail@nixpi.local` skips the tunnel entirely (mDNS).
- **Boot / reboot:** the connector is `wantedBy = multi-user.target`
  (`modules/nixos/cloudflared.nix:66`) and auto-starts. A reboot needs
  **nothing** — the token file survives on disk and the tunnel re-registers on
  its own.

### What you never do

- **Never** run `cloudflared tunnel login` or manage a `cert.pem` — this is a
  remotely-managed (token) tunnel; there is no origin-cert login flow.
- **Never** install WARP, an IdP, or a Cloudflare Access policy in front of SSH
  — auth is the SSH key, full stop (unless/until Phase 2 below is adopted).
- **Never** perform an interactive login at boot or when SSHing.
- **Never** put a token in argv or in Nix/the store — it is only ever a plain
  `/etc/secrets/cloudflared-token` `EnvironmentFile`.

---

## 11. Where this is headed — Cloudflare One for MCP aggregation

The LiteLLM proxy container (a previous iteration of this repo) is **gone
entirely** — no litellm module, image, terranix, or compose file exists on
this branch. It is being replaced by a **Cloudflare One-native** option for
aggregating MCP tool access, still to be designed. See the **cloudflare-one**
skill (`.claude/skills/cloudflare-one/SKILL.md`) for the general CF One
guidance this repo will draw on, and
[`docs/cloudflare-one-evaluation.md`](cloudflare-one-evaluation.md) for the
existing ZTIA (SSH-specific) evaluation and its "declined for now, revisit
triggers" decision — which is a separate question from the MCP-aggregation
direction referenced here.

---

## 12. Wiring reference

| Concern | File:line |
|---|---|
| Connector option + unit + hardening | `modules/nixos/cloudflared.nix` |
| Local reverse-proxy/router (behind the tunnel) | `modules/nixos/caddy-proxy.nix` |
| sshd keys-only, no root/password | `modules/nixos/core.nix:26-36` |
| Authorized SSH key (`ismail`) | `modules/nixos/core.nix:21-23` |
| mDNS `<host>.local` (avahi) + UDP 5353 | `modules/nixos/core.nix:38-53` |
| `nixpi` enables the connector + Caddy | `hosts/nixpi.nix:55-63` |
| `nixvm` — no tunnel, no Caddy (sandbox) | `hosts/nixvm.nix` |
| `macos` — client only, no server modules | `hosts/macos.nix` |
| Token file (operator-placed, plain) | `/etc/secrets/cloudflared-token` on `nixpi` |
| Tunnel + DNS provisioning script | `scripts/cf-one-provision.sh` |

### Related skills

- `cloudflared-tunnel` — client-side setup + `scripts/cf-one-provision.sh` (token provisioning).
- `nixos-flake-install` / `utm-vm-provision` / `nixvm-utm-prebuild-on-devcontainer` — bring up `nixvm` itself.
- `cloudflare-one` — general Cloudflare One guidance for the upcoming MCP-aggregation direction.
