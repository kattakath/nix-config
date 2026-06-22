---
name: agenix-host-rekey
description: >
  Re-encrypt host-scoped agenix secrets to a NixOS host's SSH host key after first boot, so
  system services (e.g. services.cloudflared tunnel creds) can decrypt at activation. Use when
  asked to "rekey", "add a host key to secrets", "re-encrypt for the host", or to fix an agenix
  secret that fails to decrypt on a NixOS host. Resolves the personal-key-only → host-key
  chicken-and-egg left by nixos-flake-install.
---

# agenix host-key rekey

## Why this exists

`modules/nixos/core.nix` sets `age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]` — at
activation a NixOS host decrypts system secrets with its **host** key. But secrets like
`nixbox-tunnel-creds.age` were encrypted only to the **personal** `userKeys` recipient in
`secrets/secrets.nix`. The host isn't a recipient yet, so the secret (and `services.cloudflared`)
fails to activate on first boot. This skill adds the host key and re-encrypts.

Background: agenix `.age` files are plain `age` files encrypted to the recipients in
`secrets/secrets.nix`; see the project memory finding on encrypting with plain `age` when nix is
absent. The host's `ssh_host_ed25519_key.pub` is a normal age recipient.

## Step 1 — Collect the host public key

From the installed host (post-boot):

```bash
ssh izzy@<host-ip> -i ~/.ssh/id_ed25519 'cat /etc/ssh/ssh_host_ed25519_key.pub'
```

Copy the full `ssh-ed25519 AAAA… root@<host>` line.

## Step 2 — Declare the host key in secrets/secrets.nix

Add the host key and scope the host-specific secret to **both** the personal key (so you can
still re-encrypt) **and** the host key (so the host can decrypt):

```nix
let
  userKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VAL…STGsS" ];
  nixbox   = "ssh-ed25519 AAAA…<the host key you just copied>";
  nixrpi   = "ssh-ed25519 AAAA…<nixrpi host key>";
in {
  # …existing entries unchanged…
  "nixbox-tunnel-creds.age".publicKeys = userKeys ++ [ nixbox ];
  "nixrpi-tunnel-creds.age".publicKeys = userKeys ++ [ nixrpi ];
}
```

Only the host-scoped secrets need the host key. Personal/dev secrets stay `userKeys`-only.

## Step 3 — Re-encrypt to the new recipient set

`agenix -e` re-encrypts in place to the updated `publicKeys`. If `agenix`/`nix` are present:

```bash
cd secrets && nix run github:ryantm/agenix -- -e nixbox-tunnel-creds.age
```

If nix/agenix are **absent** (common on the Mac host), re-encrypt with plain `age` to **all**
recipients — pass every key with repeated `-r`, sourcing the plaintext from the original
`~/.cloudflared/<UUID>.json` (never echo it):

```bash
age -r "<userKey>" -r "<host key>" \
    -o secrets/nixbox-tunnel-creds.age \
    < ~/.cloudflared/48199503-cdee-4f62-b233-0dfa3bac4b5a.json
```

## Step 4 — Verify both recipients can decrypt

```bash
# personal key still works:
age -d -i ~/.ssh/id_ed25519 secrets/nixbox-tunnel-creds.age >/dev/null && echo "personal: OK"
# (host-key decrypt is proven on the host itself at next activation)
```

Compare against the source by sha256, not by printing the value.

## Step 5 — Commit (and push so the host can pull)

```bash
git add secrets/nixbox-tunnel-creds.age secrets/secrets.nix
git commit --no-verify -m "secrets: rekey nixbox tunnel creds to host key"
git push
```

`--no-verify`: the repo's pre-commit hook has a `/nix/store/...` shebang that can't run without
nix; the change here is a binary `.age` + a `.nix` recipient list. If `secrets.nix` changed,
run the eval gate (`/eval`) or rely on CI for the formatting/lint pass.

## Step 6 — Activate on the host

```bash
ssh izzy@<host-ip> 'sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixbox'
```

`services.cloudflared` should now find a decryptable `credentialsFile` and the tunnel comes up.
