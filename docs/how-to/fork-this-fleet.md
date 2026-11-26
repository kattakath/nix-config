# Fork this for your own fleet

This is one operator's config. `loginName` in `modules/parts/identity.nix` is that operator's
POSIX account (`/Users/<loginName>` and `home-manager.users.<loginName>`), so it cannot
activate as-is on a Mac with a different login. You have two ways to make it yours.

## The quick way: no fork at all

Scaffold a small consumer flake that uses this repo as its engine (`lib.mkDarwin`, your own
identity, your own host deltas):

```bash
mkdir my-fleet && cd my-fleet
nix flake init -t github:kattakath/nix-config
```

Then follow the scaffolded [`templates/default/README.md`](../../templates/default/README.md):
edit the identity, `git init && git add -A`, `nix run .#macos`.

## The full fork

Use this when you want to change the engine itself, or run `bootstrap.sh` against your own
copy.

1. **Fork** the repo on GitHub.
2. In `modules/parts/identity.nix`, set `loginName` to **your macOS login** (`id -un`), and set
   `orgName`, `userName` and `domainName` to your own. Commit and push. (Running the on-disk
   copy of `bootstrap.sh`? Also set `FLAKE_DEFAULT` in it.)
3. On your fresh Mac, run it **pointing at your fork**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/<you>/nix-config/main/bootstrap.sh \
     | bash -s -- --flake=github:<you>/nix-config
   ```

   It activates `#macos`. Your SSH keys are yours to generate and register
   ([`new-mac-runbook.md`](../new-mac-runbook.md)).

The `loginName` guard makes this safe. If your login does not match the flake's `loginName`,
`bootstrap.sh` stops **before** activating and tells you to fork. It never half-activates
Home Manager for a user that does not exist.

## Trust model

You are piping remote code into `bash`, and it uses `sudo`.

- **The anchor** is the repo over TLS from `raw.githubusercontent.com` — your own fork, in the
  fork flow. Put a commit SHA in place of `/main/` for a stronger guarantee.
- **The bytes are linted.** `bootstrap.sh` is exactly what CI shellchecks (the `bootstrap-lint`
  check).
- **A truncated download runs nothing.** The whole script sits inside one brace group.
- **No secret transits the pipe.** Nothing in it reads a secret. `osascript` shows only
  notices, confirmations and the reboot offer, never authentication. Privilege escalation goes
  through `sudo` / Touch ID.
