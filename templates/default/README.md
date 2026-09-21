# Your fleet, on the nix-config engine

Scaffolded by `nix flake init -t github:kattakath/nix-config`. This flake
**consumes** the public [kattakath/nix-config](https://github.com/kattakath/nix-config)
engine via its `lib.mkDarwin` — no fork needed. You own two small files:

| File | What you edit |
|---|---|
| `flake.nix` | your identity (`loginName` / `fullName` / `userEmail` / `domainName`) |
| `hosts/macos.nix` | your host deltas — Homebrew apps, engine overrides |

**Prerequisite:** [Determinate Nix](https://determinate.systems/nix-installer/)
is installed (`curl -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate`).

## The 3 steps

1. **Edit the identity** in `flake.nix`: set `loginName` to your macOS login
   (`id -un` — it becomes `/Users/<loginName>`, and activation fails for a
   login that doesn't exist), plus `fullName`, `userEmail`, `domainName`.
2. **Make it a git repo** — flakes evaluate the git tree, so untracked files
   are invisible:

   ```bash
   git init && git add -A
   ```

3. **Activate:**

   ```bash
   nix run .#macos
   ```

   Thereafter: `sudo darwin-rebuild switch --flake .#macos` (nix-darwin requires root for
   system activation).

## What you inherit

`hostname = "generic-darwin"` imports the engine's neutral darwin layer — the system
modules, the shared Home Manager profile and its capsules, **nothing operator-specific**:
no CI runners, no Gmail accounts, no Homebrew cask list of someone else's (every
`OPERATOR-ONLY`-marked block in the engine stays in the engine's own `hosts/macos.nix`).
Your `hosts/macos.nix` merges on top: add to lists, flip a `local.*` switch, or
`lib.mkForce` to replace an engine value. Browse the engine's `modules/` to see what
there is; every capsule is off until you enable it.

## Your secrets on a new machine

Personal tokens live in the macOS **login Keychain** (`secret set <NAME>`), never in this
flake. To make them recoverable, opt into the GCP Secret Manager backend — every human here
has a Google Workspace identity, so recovery is gated on that one login:

1. Install Determinate Nix, `git init && git add -A`, `nix run .#macos` (the steps above).
2. In `hosts/macos.nix`, set
   `home-manager.users.<login>.local.keychainSecrets.backend.type = "gcp";` and re-activate.
   The project id is **not** written here — the commands read `gcloud config get-value project`.
3. `gcloud auth login` (your Workspace account), and enable the Secret Manager API on the
   project once.
4. `secrets-rehydrate` → the Keychain is repopulated; open a new shell. Touch ID prompts on
   later reads behave exactly as before.

`secrets-status` shows what is cached, what is in the backend and whether they agree
(hashes, never values). `secrets-push <SERVICE>` sends one Keychain item to the backend.
None of these is ever run by activation. With the backend left at `"none"` the Keychain is
the **only** copy of your secrets — back it up yourself before wiping a Mac.

The same rule for cloud CLIs: `local.cloudCli.aws.enable = true` installs the AWS CLI and
`~/.aws/config.example` with placeholders; the real `~/.aws/config` (account ids, roles,
regions) is yours, written locally, never committed.
