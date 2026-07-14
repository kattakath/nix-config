# nixvm runbook — headless QEMU/HVF, no UTM

`nixvm` is the `aarch64-linux` self-hosted CI runner. `.github/workflows/nix-ci.yml`
targets it with `runs-on: [nixvm, aarch64-linux]`, so **when nixvm is down, every PR
blocks on a job that can never be scheduled** — it queues forever rather than failing.

It runs as a plain `qemu-system-aarch64` process kept alive by a launchd daemon
(`modules/darwin/nixvm-qemu.nix`), declared by the Mac that hosts it.

## Why not UTM (and why not "bare metal")

Linux on Apple Silicon **requires virtualisation**. There is no bare-metal option
short of Asahi replacing macOS. What *can* go is every layer above QEMU — and it did:

| dropped | reason |
| --- | --- |
| UTM | Not CLI-provisionable. `utmctl` never sees a hand-authored bundle, and the osascript fallback is blocked by TCC (**error -1728**) — a permission that cannot be granted programmatically, so it fails on exactly the machine that matters: a freshly reset one. UTM is only a GUI wrapper around QEMU anyway. |
| Docker Desktop + devcontainer | Was only there to build a qcow2. |
| the prebuilt qcow2 (`nixvm-image`) | Needs `requiredSystemFeatures = ["kvm"]`, and Docker Desktop on Apple Silicon exposes no `/dev/kvm`. Unbuildable anywhere in this fleet. Removed from `packages`. |

nixpkgs' `qemu` is codesigned with `com.apple.security.hypervisor`, so `-accel hvf`
gives real hardware acceleration with no entitlement work and no GUI.

## The one thing that will silently break the runner

`gh-runner-token-nixvm.age` is agenix-encrypted **to nixvm's SSH host key**. A fresh
VM generates its own host key on first boot, which will *not* match the `nixvm`
recipient in `secrets/secrets.nix` → agenix cannot decrypt → the runner never starts,
**while the VM boots and SSHs perfectly**. Nothing looks broken. CI just hangs.

So the host key is **pre-generated on the Mac and planted at install time**, which
makes the recipient correct *before the machine exists*:

```sh
ssh-keygen -t ed25519 -N "" -f extra-files/etc/ssh/ssh_host_ed25519_key
# put the PUBLIC half in secrets/secrets.nix as `nixvm`, then:
cd secrets && agenix -r -i ~/.ssh/id_ed25519
# ...and commit. If the re-key is not PUSHED, a later
# `nixos-rebuild --flake github:…#nixvm` pulls the OLD recipient and breaks decryption.
```

## Provision / reinstall

Full procedure: the **nixvm-qemu-provision** skill. Shape of it:

1. Build the installer ISO (`nix build .#nixvm-installer-iso`) — needs no KVM.
2. Boot a blank qcow2 + the ISO under QEMU, headless, `hostfwd=tcp::2222-:22`.
3. Pre-generate the host key and re-key agenix (above).
4. `nixos-anywhere --flake .#nixvm --build-on remote --extra-files <dir> --target-host root@localhost --ssh-port 2222`.
   `--build-on remote` means the **guest builds its own closure** — the Mac never
   needs an aarch64-linux builder, so no Determinate Linux builder and no Docker.

### Two traps, both hit for real

- **Reset the EDK2 NVRAM after installing.** The install leaves a boot entry the
  firmware cannot follow, and EDK2 drops to the **UEFI Shell** instead of falling
  back to `\EFI\BOOT\BOOTAA64.EFI`. Symptom: `Shell>` on the serial console and SSH
  never comes up. Fix: `cp $(nix build --print-out-paths nixpkgs#qemu)/share/qemu/edk2-arm-vars.fd ~/nixvm/efivars.fd`.
- **Detach the ISO for the second boot.** Leave the CD attached and the firmware
  prefers it, so the VM boots the installer again instead of the system you built.

## Operate

```sh
sudo launchctl kickstart -k system/org.nixos.nixvm-qemu   # restart the VM
tail -f ~/nixvm/serial.log                                # guest console
ssh -p 2222 ismail@localhost                              # get in
nix run nixpkgs#gh -- api repos/ismailkattakath/nix-config/actions/runners \
  --jq '.runners[] | "\(.name) \(.status)"'               # is it registered?
```

The runner name is `nixvm-ismailkattakath-nix-config-01` — github-nix-ci hardcodes
`<host>-<owner>-<repo>-<NN>` (`nix/module.nix:180`); it is not configurable. Harmless:
workflows dispatch on **labels**, never on the name.

## Resize

The qcow2 is sparse — a big virtual disk costs nothing until used. Growing it needs
the guest to follow, because disko gives root `size = "100%"`:

```sh
qemu-img resize ~/nixvm/disk.qcow2 128G     # VM stopped
# in-guest, after boot:
sudo growpart /dev/vda 2 && sudo resize2fs /dev/vda2
```
