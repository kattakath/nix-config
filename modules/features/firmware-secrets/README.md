# firmware-secrets

**Reflash-safe secrets for headless NixOS devices.** Plant a secret on the device's
FAT *firmware* partition from another machine; a boot-time oneshot copies it into a
root-only `/run` file **before** the consuming service starts. The secret is never
bound to the SSH host key, so a fresh SD/USB flash doesn't lock you out.

> **Provenance.** This was `github.com/kattakath/nix-firmware-secrets`, a standalone
> MIT flake, until ADR-002 ([`docs/monoflake-capsule-adr.md`](../../../docs/monoflake-capsule-adr.md))
> collapsed the seven satellites into this repo as *capsules*. The code arrived by
> plain copy; the git history stays in the archived origin repo. MIT © Ismail Kattakath.

## The problem it solves

`agenix` and `sops-nix` decrypt at activation using the machine's **SSH host key**.
But re-flashing an SD card **mints a new host key** — so those secrets can no longer
be decrypted, and a headless device (no console) never comes back. The classic
example: a Raspberry Pi whose only remote path is a Cloudflare tunnel whose token
*is* one of those secrets. One reflash and it's bricked-until-console.

The FAT firmware partition is the one thing you can write from another machine
**after** flashing. So: plant the secret there, and let NixOS copy it to `/run` at
boot. No host key involved.

```
[laptop]  flash secret-free image ─► plant token on FAT partition
                                          │
[device boot]  firmware mounted ─► oneshot copies token ─► /run/token (0600)
                                          │
               cloudflared / wpa_supplicant reads /run/token ─► online
```

## How it is wired here

The capsule registers itself as `flake.modules.nixos.firmware-secrets` (flake-parts'
own module registry). [`modules/parts/compose.nix`](../../parts/compose.nix) threads
it into `mkNixos`'s `specialArgs` as `firmwareSecretsModule`, and
[`hosts/nixpi.nix`](../../../hosts/nixpi.nix) imports it from there — nothing outside
this directory imports its files by path, which is what makes it a capsule.

```nix
services.firmwareProvisioning.files.my-token = {
  source     = "my-token";              # basename planted on the FAT partition
  target     = "/run/my-token";         # root-only /run file your service reads
  required   = true;                    # fail the unit if the plant is missing
  before     = [ "my-service.service" ];
  requiredBy = [ "my-service.service" ];
};
```

`hosts/nixpi.nix` is the live example: the Cloudflare Tunnel connector token
(`required`) and the Wi-Fi `wpa_supplicant.conf` (optional — absent means the Pi
stays LAN-only rather than restart-looping a supplicant).

### The unit names are a load-bearing contract

`services.firmwareProvisioning` derives `firmware-file-<key>.service` from each
attribute key, and `hosts/nixpi.nix` names those units back by hand in its
`before` / `after` / `requiredBy` edges. A rename anywhere in that triangle still
evaluates and still `--dry-activate`s on an already-provisioned card — it only bites
on the NEXT FLASH. `checks.<system>.nixpi-firmware-names`
([`modules/parts/checks.nix`](../../parts/checks.nix)) pins all four names for
exactly that reason. Do not relax it.

### Options (`services.firmwareProvisioning`)

| Option | Default | Meaning |
|---|---|---|
| `firmwareDir` | `/boot/firmware` | Mount point of the FAT partition |
| `docsHint` | `""` | Text appended to the "source not found" message |
| `files.<name>.source` | — | Basename planted on the partition |
| `files.<name>.target` | — | Destination `/run` path |
| `files.<name>.mode` | `0600` | Mode of the installed file |
| `files.<name>.required` | `false` | Fail the unit if the plant is absent |
| `files.<name>.postInstall` | `""` | Shell to run after install |
| `files.<name>.{before,requiredBy}` | `[ ]` | systemd `Before=` / `RequiredBy=` on the consuming unit |
| `files.<name>.wantedBy` | `[ "multi-user.target" ]` | systemd `WantedBy=` |

## Planting from macOS

The satellite shipped a `firmware-plant` app for this. It did **not** come along:
this repo already owns that procedure as
[`packages/nixpi-provision.nix`](../../../packages/nixpi-provision.nix), the
`nixpi-provision` flake app the flashing runbook tells the operator to run.

```sh
nix run .#nixpi-provision           # plant/update token + Wi-Fi on a mounted card
nix run .#nixpi-flash -- --disk /dev/diskN --release   # flash, then auto-plant
```

Full procedure — including the full verified `dd` write — is
[`docs/nixpi-sd-flashing-runbook.md`](../../../docs/nixpi-sd-flashing-runbook.md).

## Security model — read this

- The FAT partition is **world-readable on the card** and unencrypted. Treat a
  planted secret as *exposed to anyone with physical access to the card*.
- The `/run` copy is `0600` root-only, and lives on tmpfs (never the disk).
- This is the right trade-off for *appliance* secrets (tunnel tokens, Wi-Fi PSKs)
  where the alternative is a bricked headless device. It is **not** a replacement
  for `agenix`/`sops-nix` for multi-machine fleets, servers, or high-value secrets.
  This fleet runs both: see [`docs/secrets-and-keychain.md`](../../../docs/secrets-and-keychain.md).

## When to use something else

| You want… | Use |
|---|---|
| Git-encrypted secrets, multi-machine fleets, servers | [sops-nix](https://github.com/Mic92/sops-nix) / [agenix](https://github.com/ryantm/agenix) |
| Secrets only inside `nix develop` | [agenix-shell](https://github.com/aciceri/agenix-shell) |
| A headless device that gets re-flashed and can't lose network/tunnel | **this** |
