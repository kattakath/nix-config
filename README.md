# nix-config

> One declarative Nix flake for every machine I run — my Mac, my NixOS VM, a Raspberry Pi, and a prebuilt devcontainer.

[![flake-check](https://github.com/ismailkattakath/nix-config/actions/workflows/flake-check.yml/badge.svg)](https://github.com/ismailkattakath/nix-config/actions/workflows/flake-check.yml)
[![build-devcontainer](https://github.com/ismailkattakath/nix-config/actions/workflows/build-devcontainer.yml/badge.svg)](https://github.com/ismailkattakath/nix-config/actions/workflows/build-devcontainer.yml)
[![gitleaks](https://github.com/ismailkattakath/nix-config/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/ismailkattakath/nix-config/actions/workflows/gitleaks.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

A single Nix flake that manages complete, reproducible system configurations across several hosts and one container image. There is one source of truth for everything — packages, dotfiles, services, and system settings — and per-platform differences live in composable modules rather than ad-hoc shell scripts.

## What it manages

| Host | Platform | System | Role |
|------|----------|--------|------|
| `nixcon` | macOS via [nix-darwin](https://github.com/LnL7/nix-darwin) | `aarch64-darwin` | Apple Silicon workstation |
| `nixbox` | NixOS VM (UTM / QEMU) | `aarch64-linux` | Local Linux VM |
| `nixrpi` | NixOS on Raspberry Pi 4 | `aarch64-linux` | Headless Pi |
| devcontainer | Nix-built OCI image | multi-arch | Reproducible dev environment |

User environments are layered on with [Home-Manager](https://github.com/nix-community/home-manager), and the devcontainer image is prebuilt and published to GHCR so it starts with a warm Nix store.

## Quick start

Everything below assumes [Nix with flakes enabled](https://nixos.org/download).

```bash
# Evaluate every output + run formatting / lint / pre-commit checks (the test suite).
# Flakes only see tracked files, so stage first:
git add -A && nix flake check

# Enter the dev shell (nixd LSP, treefmt, home-manager; installs the pre-commit hook).
nix develop

# Format + lint-fix all .nix files via treefmt (nixfmt + statix + deadnix).
nix fmt

# List every exported configuration and package.
nix flake show
```

### Activate a host

```bash
darwin-rebuild switch --flake .#nixcon   # macOS
nixos-rebuild  switch --flake .#nixbox    # NixOS VM
nixos-rebuild  switch --flake .#nixrpi    # Raspberry Pi
```

### Boot the NixOS VM (no UTM needed)

```bash
nix run .#nixbox-vm     # QEMU + Apple HVF; SSH forwarded to localhost:2222
```

### Use the devcontainer

The devcontainer image is prebuilt and published — pull it directly:

```bash
docker pull ghcr.io/ismailkattakath/devcontainer:latest
```

Or just open the repo in a devcontainer-aware editor; `.devcontainer/devcontainer.json` references the same published image.

## Repository layout

```
flake.nix       Entry point: inputs, darwin/nixos configurations, packages, devShells, checks
flake.lock      Pinned input revisions (bumped via `nix flake update`, never hand-edited)
treefmt.nix     Single source of truth for formatting + lint (drives nix fmt, CI, and the hook)
hosts/          Per-host entry profiles (nixcon.nix, nixbox.nix, nixrpi.nix)
modules/        Reusable modules, split by platform (darwin/ linux/ nixos/ shared/)
packages/       Nix-built artifacts (runtime container image, devcontainer image, VM launcher)
secrets/        agenix-encrypted, host-scoped service credentials (no plaintext secrets)
.claude/        Repo-local Claude Code agents, commands, hooks, and rules
```

Platform branching lives in `modules/` behind `lib.mkIf`, so host profiles stay declarative and platform-agnostic.

## How CI works

The [`flake-check`](https://github.com/ismailkattakath/nix-config/actions/workflows/flake-check.yml) workflow evaluates the whole flake across the canonical system triple — `aarch64-darwin`, `x86_64-linux`, and `aarch64-linux` (the last via QEMU emulation) — plus a `treefmt` + `pre-commit` lint gate that builds the same derivations `nix fmt` and the commit hook run locally. A public [Cachix](https://www.cachix.org/) cache (`ismailkattakath`) is consumed read-only by every host and populated by CI on `main`.

- [`build-devcontainer`](https://github.com/ismailkattakath/nix-config/actions/workflows/build-devcontainer.yml) builds, smoke-tests, and publishes the multi-arch devcontainer image to GHCR.
- [`gitleaks`](https://github.com/ismailkattakath/nix-config/actions/workflows/gitleaks.yml) scans every push and PR (and weekly) for leaked secrets.

## Secrets

No plaintext secrets live in this repo. System/service credentials are encrypted with [agenix](https://github.com/ryantm/agenix), scoped to a host's SSH key and decrypted at activation; personal tokens stay out of Nix and git entirely. The Cachix substituter is public and read-only (URL + public key, no token). See [SECURITY.md](./SECURITY.md) for the full model.

## Contributing

Contributions and issues are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md) for the workflow and the git-purity rule, and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE) © 2026 Ismail Kattakath
