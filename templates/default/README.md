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

   Thereafter: `darwin-rebuild switch --flake .#macos`.

## What you inherit

`hostname = "macos"` imports the engine's full `hosts/macos.nix` profile —
its system defaults, Home Manager profile, and Homebrew app list. Your
`hosts/macos.nix` merges on top: add to lists, or `lib.mkForce` to replace an
engine value (it already force-disables the engine's operator-specific CI
runners and Gmail-MCP accounts). Browse the engine's `hosts/` and `modules/`
to see what else there is to override.
