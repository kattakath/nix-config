---
name: nixvm-qemu-provision
description: >
  Create the nixvm sandbox VM on macOS as a plain headless QEMU/HVF process (no UTM), and install
  NixOS into it with nixos-anywhere --build-on remote. Use when asked to "make the VM", "rebuild
  nixvm", "recreate nixvm", "provision the sandbox VM", "reinstall nixvm", "nixvm is gone", "set up
  the aarch64-linux CI runner VM", or "install NixOS in QEMU on the Mac". Covers the pre-generated
  SSH host key that agenix depends on, the installer ISO, the EDK2 NVRAM reset that stops the VM
  dropping to the UEFI Shell after install, and detaching the ISO before the second boot. This is
  the CURRENT, VERIFIED path — it supersedes utm-vm-provision.
---

# nixvm provisioning — headless QEMU + HVF on macOS

`nixvm` is the fleet's **aarch64-linux sandbox VM** and the **only aarch64-linux CI runner**. It
runs on the Mac as an ordinary `qemu-system-aarch64` process with HVF acceleration. **UTM is not
involved.** (The old `utm-vm-provision` skill is kept only for UTM-specific reference material; its
"create the VM from the CLI, NO GUI required — VERIFIED" claim is **false on a fresh Mac** —
`utmctl` never sees a hand-authored bundle, and the `osascript` restart-UTM workaround is blocked by
TCC with error **-1728** "not allowed assistive access", which cannot be granted programmatically.)

## Read this before you touch anything

- **The SSH host key MUST be pre-generated on the Mac and re-keyed into `secrets/secrets.nix`
  BEFORE you install.** This is the single most important step in the whole procedure. See §1.
- **Do not try to build `packages.aarch64-linux.nixvm-image` (the qcow2).** It is a
  `nixos-disk-image` derivation and carries `requiredSystemFeatures = [ "kvm" ]`:

  ```
  error: Cannot build 'nixos-disk-image.drv'.
         Reason: missing system features
         Required features: {kvm}
         Available features: {benchmark, big-parallel, nixos-test, uid-range}
  ```

  **Nothing in this fleet has `/dev/kvm`.** Not macOS (HVF is not KVM), not the Pi (it is the
  deploy target, not a builder), and not the repo devcontainer — Docker Desktop on macOS does not
  expose `/dev/kvm` to containers, verified even on an M3 Pro (`ls -l /dev/kvm` → No such file).
  A whole skill (`nixvm-utm-prebuild-on-devcontainer`) was built on the premise that the
  devcontainer could produce that qcow2; it could not, and is now marked SUPERSEDED/defunct (it
  still lives under `.claude/skills/` for reference). **We do not need a
  prebuilt qcow2 at all any more** — `nixos-anywhere --build-on remote` makes the guest build
  itself, so an empty disk plus the installer ISO is enough.
- The installer ISO (`packages.aarch64-linux.nixvm-installer-iso`) has **no** `requiredSystemFeatures`
  and builds anywhere aarch64-linux is available. Check rather than trust:
  ```bash
  nix derivation show "$(nix eval --raw .#packages.aarch64-linux.nixvm-installer-iso.drvPath)" \
    | grep requiredSystemFeatures     # → absent
  ```
  **Bootstrap warning:** CI builds that ISO with `runs-on: [nixvm, aarch64-linux]` — i.e. the VM is
  the only machine that can build the thing that recreates the VM. If `nixvm` is already dead, CI
  cannot help you; get the ISO from a prior artifact, from Cachix, or from any other aarch64-linux
  box with Nix.
- `nixpkgs`' `qemu` on darwin **is codesigned with `com.apple.security.hypervisor`**, so
  `-accel hvf` works out of the box. No Homebrew QEMU, no manual `codesign`.
- Destructive: `nixos-anywhere` wipes the target disk. It only ever touches the qcow2 you point it
  at, but confirm the path before you run it.

## 1. Pre-generate the SSH host key and re-key secrets — DO THIS FIRST

The nixvm CI runner's GitHub PAT lives in `secrets/gh-runner-token-nixvm.age`, agenix-encrypted to
the **`nixvm` host key recorded in `secrets/secrets.nix`**. agenix decrypts it at activation using
`/etc/ssh/ssh_host_ed25519_key`. So the host key has to exist, and be a known recipient, *before the
VM first boots*.

**If you skip this and let the fresh guest generate its own host key**, the recipient in
`secrets.nix` is stale → agenix cannot decrypt the PAT → `github-nix-ci`'s runner service **never
starts** → every PR's `build (aarch64-linux)` leg queues forever. The VM boots fine, SSH answers,
`systemctl` looks healthy. **It fails completely silently.** That is why the key is planted, not
harvested.

```bash
# 1. Generate the host key pair on the Mac (no passphrase — sshd needs it unencrypted).
EXTRA=$(mktemp -d)/extra
mkdir -p "$EXTRA/etc/ssh"
ssh-keygen -t ed25519 -N "" -C nixvm -f "$EXTRA/etc/ssh/ssh_host_ed25519_key"
chmod 600 "$EXTRA/etc/ssh/ssh_host_ed25519_key"
chmod 644 "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"

# 2. Put the PUBLIC half into secrets/secrets.nix as the `nixvm` recipient.
cut -d' ' -f1,2 "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"
#    → edit secrets/secrets.nix:  nixvm = "ssh-ed25519 AAAA…";

# 3. Re-key so gh-runner-token-nixvm.age is encrypted to the NEW nixvm key.
cd secrets && nix run github:ryantm/agenix -- -r -i ~/.ssh/id_ed25519
```

`agenix -r` re-keys **every** secret, and age never re-encrypts byte-identically (fresh ephemeral
keys each time), so secrets that have nothing to do with `nixvm` come back "modified" with no
semantic change. **Revert that churn** so the commit contains only `gh-runner-token-nixvm.age` +
`secrets.nix`. (`packages/key-recovery.nix` does the same dance for `macos` and derives its
keep-list from `secrets.nix`.)

Never echo the private half. `$EXTRA` is handed to `nixos-anywhere` in §4 and should be deleted
after.

## 2. Create the disk and the firmware variable store

```bash
mkdir -p ~/nixvm
QEMU=$(nix build --no-link --print-out-paths nixpkgs#qemu)

# Empty sparse disk. 128G VIRTUAL is fine — qcow2 only allocates what's written (~4G actual).
qemu-img create -f qcow2 ~/nixvm/disk.qcow2 128G

# EDK2 firmware: CODE is read-only from the store; VARS must be a private WRITABLE copy.
cp "$QEMU/share/qemu/edk2-arm-vars.fd" ~/nixvm/efivars.fd
chmod u+w ~/nixvm/efivars.fd
```

## 3. Boot the installer ISO

```bash
QEMU=$(nix build --no-link --print-out-paths nixpkgs#qemu)
ISO=/path/to/nixvm-installer.iso        # see §0 note — CI artifact or any aarch64-linux builder

"$QEMU/bin/qemu-system-aarch64" \
  -M virt -accel hvf -cpu host -smp 8 -m 16384 \
  -drive if=pflash,format=raw,readonly=on,file="$QEMU/share/qemu/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file="$HOME/nixvm/efivars.fd" \
  -drive if=virtio,format=qcow2,file="$HOME/nixvm/disk.qcow2" \
  -drive if=virtio,format=raw,readonly=on,file="$ISO" \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$HOME/nixvm/serial.log" &
```

- `-accel hvf -cpu host` — native Apple Silicon virtualisation. Without `-cpu host`, HVF refuses.
- `-display none -serial file:…` — fully headless; `~/nixvm/serial.log` is your only console. Tail
  it when something goes wrong; it is where you will see the UEFI Shell prompt in §5.
- `-netdev user … hostfwd=tcp::2222-:22` — SLIRP user networking. The guest has **no routable IP**
  on the host (unlike UTM's `vmnet-shared`), so **everything goes through `localhost:2222`**. Do not
  go hunting in `arp -an`; there is nothing there.

Wait for the ISO to come up, then confirm SSH answers:

```bash
ssh -p 2222 -o StrictHostKeyChecking=no root@localhost 'uname -m'   # → aarch64
```

## 4. Install with nixos-anywhere — `--build-on remote`

```bash
cd ~/nix-config
nix run github:nix-community/nixos-anywhere -- \
  --flake .#nixvm \
  --build-on remote \
  --extra-files "$EXTRA" \
  --target-host root@localhost --ssh-port 2222
```

- **`--build-on remote` is what makes this fleet work at all.** The guest builds its own closure, so
  the Mac needs **no Linux builder** — no `linux-builder`, no remote-builder config, no
  chicken-and-egg with the nixvm CI runner.
- **`--extra-files "$EXTRA"`** copies the tree from §1 into the installed root, planting
  `/etc/ssh/ssh_host_ed25519_key{,.pub}` **before the first boot**. That is what lets agenix decrypt
  the runner PAT on boot #1.
- `--flake .#nixvm` runs disko (partition labels `nixos` ext4 root + `boot` vfat ESP, per
  `hosts/nixvm.nix`), so no manual `parted`/`mkfs`.

`nixos-anywhere` reboots the VM when it finishes. **It will not come back up cleanly — that is
expected. Go to §5.**

## 5. GOTCHA — reset NVRAM, or the VM lands in the UEFI Shell

After the install-and-reboot, the EDK2 variable store (`efivars.fd`) is left holding a boot entry it
cannot follow. Instead of falling back to the removable-media path `\EFI\BOOT\BOOTAA64.EFI`, the
firmware drops to the **UEFI Shell** and just sits there. From the outside the VM looks hung; the
only evidence is `~/nixvm/serial.log`. This cost real debugging time.

**Fix: wipe NVRAM back to the pristine template and boot with the ISO DETACHED.**

```bash
pkill -f qemu-system-aarch64            # stop the VM first
QEMU=$(nix build --no-link --print-out-paths nixpkgs#qemu)

cp "$QEMU/share/qemu/edk2-arm-vars.fd" ~/nixvm/efivars.fd   # ← reset the variable store
chmod u+w ~/nixvm/efivars.fd

# Boot the INSTALLED system: same command as §3 MINUS the ISO drive.
"$QEMU/bin/qemu-system-aarch64" \
  -M virt -accel hvf -cpu host -smp 8 -m 16384 \
  -drive if=pflash,format=raw,readonly=on,file="$QEMU/share/qemu/edk2-aarch64-code.fd" \
  -drive if=pflash,format=raw,file="$HOME/nixvm/efivars.fd" \
  -drive if=virtio,format=qcow2,file="$HOME/nixvm/disk.qcow2" \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:"$HOME/nixvm/serial.log" &
```

Two things matter and both are load-bearing:

1. **Copy `edk2-arm-vars.fd` over `efivars.fd`.** Note the asymmetric filenames — the CODE blob is
   `edk2-aarch64-code.fd`, the VARS template is `edk2-**arm**-vars.fd`. With a clean store, EDK2
   enumerates the disk and finds `BOOTAA64.EFI`.
2. **Detach the ISO.** Leave it attached and the firmware happily boots the installer again, and you
   will think the install failed when it did not.

VERIFIED: with both done, the VM boots the installed system and the CI runner comes online.

## 6. Verify

```bash
ssh -p 2222 ismailkattakath@localhost 'hostname; nproc; free -h; systemctl is-active github-runner-*'
```

Expected end state (this is what a healthy `nixvm` looks like):

- 8 vCPU, ~15 GB RAM, ~7 GB swap in the guest.
- GitHub → org (`kattakath`) → Settings → Actions → Runners shows
  **`nixvm-kattakath-01` and `nixvm-kattakath-02` ONLINE** (org runners, `num = 2`), labels `[nixvm, aarch64-linux]`.

If the runner is **absent** rather than offline, you almost certainly skipped §1 — agenix could not
decrypt `gh-runner-token-nixvm.age`. Check `journalctl -u agenix* -b` in the guest.

Delete `$EXTRA` (it holds the private host key) once you are done.

## Notes

- The guest root ext4 is smaller than the 128G virtual disk after a fresh install; growing it is a
  separate operation and is not part of this procedure.
- `nix run .#nixvm` is the **disko-install bootstrap app run from inside the live ISO** — a
  different, older path than `nixos-anywhere`, and it is not what this skill uses. Don't confuse the
  two.
- `nixvm` needs no other secret handoff — it's a sandbox with no tunnel and no public ingress
  (contrast `nixpi`, which needs `/etc/secrets/cloudflared-token`; see **cloudflared-tunnel**).

## Cross-references

- **utm-vm-provision** — SUPERSEDED by this skill. Retained only for UTM-specific reference
  (qcow2 sizing, `vmnet-shared`/ARP, UEFI boot-order quirks).
- **nixos-flake-install** — the manual in-guest `nixos-install` flow; `nixos-anywhere` replaces it
  here.
