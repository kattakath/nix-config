# cloudflared-connector

**A hardened NixOS module for a boot-time, loginless Cloudflare Tunnel connector** —
the *remotely-managed (token)* model that upstream `services.cloudflared` doesn't
support. Zero interactive login, no `cert.pem`; the token is read from an
`EnvironmentFile`, so it never lands in argv or the world-readable Nix store.

> **Provenance.** This was `github.com/kattakath/nix-cloudflared-connector`, a
> standalone MIT flake, until ADR-002 ([`docs/monoflake-capsule-adr.md`](../../../docs/monoflake-capsule-adr.md))
> collapsed the seven satellites into this repo as *capsules*. The code arrived by
> plain copy; the git history stays in the archived origin repo. MIT © Ismail Kattakath.

## Why this exists

Upstream `services.cloudflared` only drives **locally-managed** tunnels: it wants a
credentials JSON + in-repo ingress and runs `cloudflared tunnel run <uuid>` — no
token support. A **remotely-managed (token)** tunnel comes up at boot with no login
and keeps its ingress/DNS in the Cloudflare account (dashboard or IaC), not your
NixOS config. This is a small, hardened `systemd` unit for exactly that.

## How it is wired here

The capsule registers itself as `flake.modules.nixos.cloudflared-connector`
(flake-parts' own module registry). `modules/parts/compose.nix` threads it into
`mkNixos`'s `specialArgs` as `cloudflaredConnectorModule`, and
[`hosts/nixpi.nix`](../../../hosts/nixpi.nix) imports it from there — nothing
outside this directory imports its files by path, which is what makes it a capsule.

```nix
services.cloudflared-connector = {
  enable = true;
  tokenFile = "/run/cloudflared-token"; # a file with one line: TUNNEL_TOKEN=<token>
  # extraArgs = [ "--loglevel" "debug" ];      # optional
};
```

Place `tokenFile` out-of-band with a single line `TUNNEL_TOKEN=<token>`. **Never
commit the token.** The unit retries on failure, so placing the file after first
boot self-heals without a rebuild. On `nixpi` that placement is
`services.firmwareProvisioning` (the sibling `firmware-secrets` capsule) copying it off the
SD card's FAT `FIRMWARE` partition — deliberately NOT agenix, because a reflash
rotates the host key and would strand the only remote path in. See
[`docs/nixpi-sd-flashing-runbook.md`](../../../docs/nixpi-sd-flashing-runbook.md).

### Options (`services.cloudflared-connector`)

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | Enable the connector unit |
| `package` | `pkgs.cloudflared` | cloudflared package |
| `tokenFile` | `/etc/secrets/cloudflared-token` | `EnvironmentFile` with `TUNNEL_TOKEN=…` |
| `extraArgs` | `[ ]` | Extra args to `cloudflared tunnel run` |
| `restartSec` | `5` | systemd `RestartSec` |

## Security

- The token is passed via `EnvironmentFile` (env var `TUNNEL_TOKEN`), **never on the
  command line** (argv is world-readable via `/proc`) and **never in the Nix store**.
- The unit runs under `DynamicUser` with a strict `systemd` hardening profile
  (`ProtectSystem=strict`, `NoNewPrivileges`, `MemoryDenyWriteExecute`, a
  `@system-service` syscall filter, restricted address families, …).
- The token file lives on the host only (mode-lock it, e.g. `0600 root`).

## When to use something else

| You want… | Use |
|---|---|
| A **locally-managed** tunnel (credentials JSON + in-repo ingress) | upstream [`services.cloudflared`](https://search.nixos.org/options?query=services.cloudflared) |
| A **remotely-managed (token)** connector at boot, no login | **this** |

## Checks

`checks.aarch64-linux.cloudflared-connector-module` — the satellite's own eval
check, carried over verbatim: it builds a throwaway `nixosSystem` with the module
enabled and asserts the unit reads its token from an `EnvironmentFile`, keeps
`NoNewPrivileges` + `MemoryDenyWriteExecute`, and honours `extraArgs`.

A **rename inside this capsule is the dangerous edit**, not a behaviour change:
`hosts/nixpi.nix` orders the firmware-planted token file `before` /
`requiredBy` `cloudflared-connector.service` by NAME. That ordering is invisible to
`nix flake check` and to `--dry-activate` on an already-provisioned card, and only
bites on the next flash (a ~40-minute physical trip). `checks.aarch64-linux.nixpi-firmware-names`
(`modules/parts/checks.nix`) pins the four names against the live `nixpi` config.
