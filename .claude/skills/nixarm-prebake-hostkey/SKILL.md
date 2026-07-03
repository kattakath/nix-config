---
name: nixarm-prebake-hostkey
description: >
  Bake a PINNED SSH host key into the nixarm qcow2 so the Cloudflare tunnel (and any agenix
  host-scoped secret) works on FIRST BOOT — zero logins, no post-boot rekey, no in-VM
  nixos-rebuild. Use when asked to "make the tunnel come up at boot", "prebake the host key",
  "avoid rekeying every VM", "first-boot working tunnel", or when a fresh nixarm VM's
  cloudflared fails with 243/CREDENTIALS. VERIFIED end-to-end 2026-06-22 (tunnel registered with
  Cloudflare edge at boot). This is "approach b" — the alternative to post-boot agenix-host-rekey.
---

# nixarm prebake host key — first-boot-working tunnel (approach b)

## Why this exists

agenix decrypts host-scoped secrets at **activation** using `/etc/ssh/ssh_host_ed25519_key`
(`modules/nixos/core.nix` → `age.identityPaths`). A fresh NixOS image regenerates that host key
on first boot, so a secret encrypted to any *previous* key can never decrypt → `services.cloudflared`
dies with `status=243/CREDENTIALS`. Two ways out:

- **agenix-host-rekey** (the other skill): boot → collect the new host key → re-encrypt → `nixos-rebuild`.
  **Pitfall proven 2026-06-22:** an in-VM `nixos-rebuild switch` on the TCG-emulated VM is too heavy —
  it thrashed the guest into emergency mode (root locked, no console). And a plain *restart* never
  helps: the booted closure still has the old secret until a rebuild swaps it in.
- **THIS skill (approach b):** pin one host keypair offline, encrypt the secret to its public half,
  and inject the private half into the image's `/etc/ssh/` **before first boot**. agenix then decrypts
  at the very first activation. No per-VM rekey, no in-VM rebuild, tunnel up at boot.

## Hard facts that shaped the mechanism (each verified this session)

- **System agenix is an ACTIVATION-SCRIPT snippet (`agenixInstall`), NOT a systemd unit.** It runs
  in early boot *before* systemd starts services. So a `systemd.services` oneshot to plant the key
  would run **too late** — ruled out. The key must simply be *present on disk* before activation,
  which is why we inject it straight into the ext4 root (no oneshot, no `hosts/nixarm.nix` change).
- **libguestfs / virt-customize is UNAVAILABLE on aarch64** (the appliance is x86_64/i686-only in
  nixpkgs). Do not reach for it in the aarch64 devcontainer — it won't evaluate.
- **The image is qcow2 + GPT**: vfat ESP (partition 1) + ext4 root (partition 2, start sector
  526336 in the verified build — but READ it dynamically, don't hardcode).
- **`qemu-img` + `e2fsprogs` (`debugfs`) are aarch64-native** and need no KVM / no privileged mount /
  no NBD. `debugfs -w` can create `/etc/ssh/ssh_host_ed25519_key` with mode 0600 uid/gid 0 offline.
- **sshd does NOT overwrite an existing host key** → an injected key survives first boot.
- **No secret in the Nix store, ever.** The pure image (`nix build .#nixarm-image`) contains NO key.
  The private key lives only as agenix ciphertext (`secrets/nixarm-hostkey.age`, encrypted to the
  personal key) and as plaintext **only** in container `/tmp` during injection (shredded after).

## One-time pinning (offline, on the Mac)

```bash
WORK=$(mktemp -d /tmp/nixarm-pin.XXXXXX); chmod 700 "$WORK"
ssh-keygen -t ed25519 -N "" -C "root@nixarm" -f "$WORK/ssh_host_ed25519_key"
PUB=$(cat "$WORK/ssh_host_ed25519_key.pub")          # → the pinned PUBLIC key
USERKEY=$(ssh-keygen -y -f ~/.ssh/id_ed25519)        # your personal recipient

# Encrypt the PRIVATE key to your personal key (only ciphertext is ever committed):
age -r "$USERKEY" -o secrets/nixarm-hostkey.age "$WORK/ssh_host_ed25519_key"
```

Then in `secrets/secrets.nix`:
- set the `nixarm` recipient to the **pinned public key** (`$PUB`),
- add `"nixarm-hostkey.age".publicKeys = userKeys;`  (**build-time only — never wire into any
  host's `age.secrets`**; it would needlessly copy a host private key into a running system).

Re-encrypt the tunnel creds to the new recipient set (decrypt with your personal key — you're still
a recipient — then re-encrypt to both):

```bash
TMP=$(mktemp); age -d -i ~/.ssh/id_ed25519 secrets/nixarm-tunnel-creds.age > "$TMP"
age -r "$USERKEY" -r "$PUB" -o secrets/nixarm-tunnel-creds.age "$TMP"
# verify BOTH recipients decrypt, compare sha256 to the source, then:
shred -u "$TMP"
```

Verify the **pinned host key itself** can decrypt (this is the whole point):
```bash
age -d -i "$WORK/ssh_host_ed25519_key" secrets/nixarm-tunnel-creds.age | sha256sum   # must match source
```

`git add -A` and commit (pinning is one-time; skip all of the above on later rebuilds).

## Per-build: build pure image, then inject (in the devcontainer)

```bash
# 1. Build the PURE image (no key inside) — see nixarm-utm-prebuild-on-devcontainer:
devcontainer exec --workspace-folder . -- bash -lc 'git add -A && nix build .#nixarm-image'

# 2. Writable copy in container /tmp:
devcontainer exec --workspace-folder . -- bash -lc 'cp $(readlink -f result)/*.qcow2 /tmp/img.qcow2 && chmod u+w /tmp/img.qcow2'

# 3. Get the plaintext key into the container as a vscode-READABLE file (0644!).
#    GOTCHA: docker cp preserves 0600 root:root → the vscode user can't read it and debugfs
#    fails "Permission denied". Fix ownership+mode as root after copy:
CID=$(docker ps -q --filter "label=devcontainer.local_folder=$(realpath .)" | head -1)
age -d -i ~/.ssh/id_ed25519 secrets/nixarm-hostkey.age > /tmp/hk        # on the Mac
ssh-keygen -y -f /tmp/hk > /tmp/hk.pub
docker cp /tmp/hk "$CID:/tmp/hk"; docker cp /tmp/hk.pub "$CID:/tmp/hk.pub"
docker exec -u root "$CID" bash -c 'chown vscode:vscode /tmp/hk /tmp/hk.pub && chmod 0644 /tmp/hk /tmp/hk.pub'
shred -u /tmp/hk /tmp/hk.pub                                             # wipe the Mac copies

# 4. Inject into the ext4 root via debugfs (offset read dynamically), then repack:
devcontainer exec --workspace-folder . -- bash -lc '
  nix shell nixpkgs#qemu nixpkgs#e2fsprogs nixpkgs#util-linux --command bash -c "
    set -e
    qemu-img convert -O raw /tmp/img.qcow2 /tmp/img.raw
    START=\$(sfdisk -d /tmp/img.raw | awk \"/2 :/{for(i=1;i<=NF;i++) if(\\\$i ~ /start=/){gsub(/[start=,]/,\\\"\\\",\\\$i); print \\\$i}}\")
    OFF=\$((START * 512)); FS=\"/tmp/img.raw?offset=\$OFF\"
    printf \"cd /etc/ssh\nwrite /tmp/hk ssh_host_ed25519_key\nsif ssh_host_ed25519_key mode 0100600\nsif ssh_host_ed25519_key uid 0\nsif ssh_host_ed25519_key gid 0\nwrite /tmp/hk.pub ssh_host_ed25519_key.pub\nsif ssh_host_ed25519_key.pub mode 0100644\nsif ssh_host_ed25519_key.pub uid 0\nsif ssh_host_ed25519_key.pub gid 0\n\" > /tmp/df.cmds
    debugfs -w -f /tmp/df.cmds \"\$FS\"
    debugfs -R \"stat /etc/ssh/ssh_host_ed25519_key\" \"\$FS\" | grep -E \"Mode|User\"
    qemu-img convert -O qcow2 /tmp/img.raw /tmp/img.qcow2.inj && mv /tmp/img.qcow2.inj /tmp/img.qcow2
    rm -f /tmp/img.raw /tmp/df.cmds /tmp/hk /tmp/hk.pub
  "'

# 5. Stream the injected qcow2 to the Mac (then chmod u+w from the Mac — VirtioFS blocks guest chmod):
devcontainer exec --workspace-folder . -- bash -lc 'cat /tmp/img.qcow2 > /workspaces/nix-config/nixarm-injected.qcow2'
chmod u+w nixarm-injected.qcow2
```

## Boot + verify (zero logins)

Create a UTM VM from `nixarm-injected.qcow2` via **utm-vm-provision §0** (heredoc plist **with the
`Sound` key**, then AppleScript `import`). Boot, find the IP by ARP, then:

```bash
# (a) VM presents the PINNED key (compare key MATERIAL only — ssh-keyscan prefixes host:port):
diff <(ssh-keyscan -t ed25519 <ip> 2>/dev/null | grep -o 'ssh-ed25519 [A-Za-z0-9+/]*') \
     <(grep -o 'ssh-ed25519 [A-Za-z0-9+/]*' "$WORK/ssh_host_ed25519_key.pub") && echo "pinned-key OK"

# (b) tunnel up at boot — registered with the edge BEFORE any login:
ssh izzy@<ip> 'systemctl is-active cloudflared-tunnel-48199503-cdee-4f62-b233-0dfa3bac4b5a.service
  sudo journalctl -u cloudflared-tunnel-48199503-cdee-4f62-b233-0dfa3bac4b5a.service | grep "Registered tunnel connection"'
# → active + 4 "Registered tunnel connection" lines (yyz01/04/06). An initial
#   "network is unreachable" line is just the pre-DHCP race; it connects ~6s in.
```

Negative control: build once WITHOUT injecting → cloudflared fails `243/CREDENTIALS`. That proves
the injection is what fixes it.

## Re-pin / revert

- **Re-pin** (key compromise / lost Mac without the .age): regenerate the keypair, redo the one-time
  steps, rebuild + reinject. Cloudflare UUID/DNS/creds are unchanged — only the age wrapping changes.
- **Revert to post-boot rekey**: drop `nixarm-hostkey.age`, restore the old comment, use
  **agenix-host-rekey**. The only durable repo change here is the recipient wrapping + the extra .age.

## Cross-references
- **nixarm-utm-prebuild-on-devcontainer** — builds the pure qcow2 this skill injects into.
- **utm-vm-provision** §0 — CLI-creates the bootable VM from the injected image.
- **agenix-host-rekey** — the post-boot alternative (approach a); use if you can't prebake.
- **cloudflared-tunnel** — the macOS client side (ProxyCommand) for reaching the host over the tunnel.
