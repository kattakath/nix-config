---
name: agenix-host-rekey
description: >
  Re-encrypt host-scoped agenix secrets to a NixOS host's SSH host key after first boot, so system
  services (e.g. the cloudflared connector token) can decrypt at activation. Use when asked to
  "rekey", "add a host key to secrets", "re-encrypt for the host", or to fix an agenix secret that
  fails to decrypt on a NixOS host. Resolves the personal-key-only → host-key chicken-and-egg that
  occurs after any fresh host provisioning (qcow2 boot or ISO install).
---

# agenix host-key rekey

## Why (read first)

`modules/nixos/core.nix` sets `age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]`, so at
activation the host decrypts system secrets with its **host** key. But `nixarm-tunnel-token.age` was
encrypted only to the **personal** `userKeys` recipient in `secrets/secrets.nix` — the host isn't a
recipient yet, so the secret (and the `cloudflared-connector` unit) fails on first boot. This skill
adds the host key as an age recipient and re-encrypts.

- **Keep names unchanged**: secret file `nixarm-tunnel-token.age`, DNS `nixarm.kattakath.com`
  (renaming the `.age` forces needless re-encryption). Owning host is `nixarm` (`hosts/nixarm.nix`),
  attr `age.secrets."nixarm-tunnel-token"`.
- The secret is a remotely-managed connector **token**: a single line `TUNNEL_TOKEN=…`, consumed by
  `modules/nixos/cloudflared.nix` via `EnvironmentFile` (not a credentials JSON, not a tunnel UUID).
- `.age` files are plain `age` files encrypted to the recipients in `secrets/secrets.nix`; the
  host's `ssh_host_ed25519_key.pub` is a normal age recipient.

## 1. Collect the host public key (post-boot)

```bash
ssh ismail@<host-ip> -i ~/.ssh/id_ed25519 'cat /etc/ssh/ssh_host_ed25519_key.pub'
```

## 2. Declare the host key in `secrets/secrets.nix`

Scope the host-specific secret to **both** the personal key (so you can re-encrypt) **and** the host
key (so the host can decrypt). Personal/dev secrets stay `userKeys`-only.

```nix
let
  userKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAq9VAL…STGsS" ];
  nixarm   = "ssh-ed25519 AAAA…<the host key you just copied>";
in {
  # …existing entries unchanged…
  "nixarm-tunnel-token.age".publicKeys = userKeys ++ [ nixarm ];
}
```

## 3. Re-encrypt to the new recipient set

With `agenix`/`nix` present (re-encrypts in place to the updated `publicKeys`):

```bash
cd secrets && nix run github:ryantm/agenix -- -e nixarm-tunnel-token.age
```

Without nix/agenix (common on the Mac) — re-encrypt with plain `age` to **all** recipients (repeated
`-r`), sourcing the plaintext token (a single `TUNNEL_TOKEN=…` line from `scripts/cf-one-provision.sh`;
never echo it):

```bash
# $TOKEN_FILE holds the one line: TUNNEL_TOKEN=…
age -r "<userKey>" -r "<host key>" \
    -o secrets/nixarm-tunnel-token.age \
    < "$TOKEN_FILE"
```

## 4. Verify both recipients can decrypt

```bash
age -d -i ~/.ssh/id_ed25519 secrets/nixarm-tunnel-token.age >/dev/null && echo "personal: OK"
# host-key decrypt is proven on the host at next activation
```

Compare against the source by sha256, not by printing the value.

## 5. Commit + push (so the host can pull)

```bash
git add secrets/nixarm-tunnel-token.age secrets/secrets.nix
git commit --no-verify -m "secrets: rekey nixarm tunnel token to host key"
git push
```

`--no-verify`: the pre-commit hook's `/nix/store/...` shebang can't run without nix; the change is a
binary `.age` + a `.nix` recipient list. If `secrets.nix` changed, run `/eval` or rely on CI.

## 6. Activate on the host

```bash
ssh ismail@<host-ip> 'sudo nixos-rebuild switch --flake github:ismailkattakath/nix-config#nixarm'
```

The `cloudflared-connector` unit now finds a decryptable `EnvironmentFile` (its `TUNNEL_TOKEN`) and
the tunnel comes up.
