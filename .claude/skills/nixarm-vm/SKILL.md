---
name: nixarm-vm
description: >
  Launch the nixarm NixOS VM on macOS via QEMU with Apple HVF acceleration — no UTM required.
  Use when asked to "run nixarm", "boot the nixarm VM", "launch nixarm without UTM", "start nixarm
  in QEMU", or "use nix run .#nixarm-vm". This is the lightweight alternative to utm-vm-provision:
  one command spins up the VM using a prebuilt qcow2, with user-mode networking and SSH forwarded
  to localhost:2222. Covers building the qcow2, first-boot SSH access, agenix rekey, and post-tunnel
  access.
---

# nixarm-vm — QEMU + HVF launcher (no UTM)

## This vs utm-vm-provision

| | **nixarm-vm** (this skill) | **utm-vm-provision** |
|---|---|---|
| Launch method | `nix run .#nixarm-vm` | UTM GUI + `utmctl` |
| Networking | User-mode NAT, `localhost:2222→22` | vmnet-shared, real `192.168.64.x` IP |
| Console | Serial on stdio | UTM GUI window only |
| QEMU monitor | `Ctrl-a c` then `quit` | Not accessible from CLI |
| Setup overhead | Minimal | GUI VM creation required |

Use this skill when you want a fast, GUI-free boot. Use **utm-vm-provision** when you need vmnet-shared networking (mDNS, routable guest IP) or the UTM GUI is already set up.

## Gotchas (read first)

- **UEFI firmware** — the launcher uses `${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd` and `edk2-aarch64-vars.fd` from the nixpkgs `qemu` package. These are only present if nixpkgs ships them with qemu (they do for aarch64 builds); they are not the system `/usr/share/qemu` files.
- **Vars copy** — on first run the script copies `edk2-aarch64-vars.fd` into the state dir (`~/.local/state/nixarm-vm/`) for boot-order persistence. If the state dir already has a `vars.fd` from a previous run it is reused.
- **User-mode networking = NAT** — the guest is not directly reachable by IP; only the forwarded port `localhost:2222` works. mDNS (`nixarm.local`) will not resolve until after the Cloudflare Tunnel is active.
- **QEMU monitor** — reach it with `Ctrl-a c` (not `Ctrl-c`, which sends SIGINT). Type `quit` to stop the VM cleanly. `Ctrl-a x` also exits.
- **HVF required** — the launcher passes `-accel hvf`. This requires macOS on Apple Silicon (or Intel Mac with HVF). It will not work inside a Linux VM or CI.
- **aarch64-linux builder required** to build the qcow2 — the repo devcontainer qualifies (Nix + flakes on Debian aarch64).

## Step 1 — Build and place the qcow2

Build on any aarch64-linux machine with Nix + flakes (the devcontainer qualifies):

```bash
# in the repo root, on the aarch64-linux builder:
git add -A
nix build .#nixarm-image
```

Copy the result to the Mac:

```bash
# from macOS (or wherever you'll run nix run):
mkdir -p ~/.local/state/nixarm-vm
scp builder:$(ssh builder 'readlink -f /path/to/nix-config/result/*.qcow2') \
    ~/.local/state/nixarm-vm/nixarm.qcow2
```

Or copy locally if the build ran on the Mac's devcontainer:

```bash
mkdir -p ~/.local/state/nixarm-vm
cp result/*.qcow2 ~/.local/state/nixarm-vm/nixarm.qcow2
```

The default disk path is `~/.local/state/nixarm-vm/nixarm.qcow2`; override with `NIXARM_DISK`.

## Step 2 — Launch

```bash
cd /path/to/nix-config
nix run .#nixarm-vm
```

The VM boots with serial output on stdio. Login prompt appears when boot completes. The SSH daemon is enabled in `hosts/nixarm.nix` — it starts automatically.

### Environment overrides

| Variable | Default | Effect |
|---|---|---|
| `NIXARM_DISK` | `~/.local/state/nixarm-vm/nixarm.qcow2` | Path to the qcow2 disk image |
| `NIXARM_MEMORY` | `2048` | RAM in MiB |
| `NIXARM_CPUS` | `4` | vCPU count |

Example — boot with 8 GiB and 6 CPUs using a custom disk:

```bash
NIXARM_DISK=~/vms/nixarm-dev.qcow2 NIXARM_MEMORY=8192 NIXARM_CPUS=6 nix run .#nixarm-vm
```

## Step 3 — First-boot SSH and agenix rekey

On first boot the host generates a fresh `ssh_host_ed25519_key`. The `nixarm-tunnel-creds.age` secret is encrypted only to the personal key placeholder — `services.cloudflared` will fail to decrypt and will not start. This is expected.

SSH into the running VM:

```bash
ssh -p 2222 izzy@localhost
```

If the host key changed (rebuild or fresh qcow2), clear the old entry first:

```bash
ssh-keygen -R '[localhost]:2222'
```

Grab the host public key:

```bash
ssh -p 2222 izzy@localhost 'cat /etc/ssh/ssh_host_ed25519_key.pub'
```

Then run the **agenix-host-rekey** skill to add this key as an age recipient and re-encrypt `nixarm-tunnel-creds.age`. That skill covers the full flow: editing `secrets/secrets.nix`, re-encrypting, committing, and activating on the host.

## Step 4 — After the tunnel is active

Once agenix-host-rekey is done and `nixos-rebuild switch` has run on the host, `services.cloudflared` starts the tunnel. Verify:

```bash
ssh -p 2222 izzy@localhost 'systemctl status cloudflared'
```

After the tunnel is up, SSH via Cloudflare ProxyCommand (see **cloudflared-tunnel** skill):

```bash
ssh izzy@nixarm.kattakath.com
```

The `localhost:2222` port-forward remains available as a fallback for as long as the QEMU process is running.

## Stopping the VM

From the serial console (stdio):

1. Press `Ctrl-a c` to enter the QEMU monitor.
2. Type `quit` and press Enter.

Or send SIGTERM to the `qemu-system-aarch64` process:

```bash
pkill -TERM qemu-system-aarch64
```

For a clean guest shutdown from another terminal:

```bash
ssh -p 2222 izzy@localhost 'sudo shutdown now'
```
