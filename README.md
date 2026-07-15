# nix-config

> One declarative Nix flake for my aarch64 fleet — my Mac, a Raspberry Pi server, a UTM/QEMU sandbox VM, and a prebuilt devcontainer.

[![build-devcontainer](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml/badge.svg)](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml)
[![gitleaks](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml)
[![FlakeHub](https://img.shields.io/endpoint?url=https://flakehub.com/f/kattakath/nix-config/badge)](https://flakehub.com/flake/kattakath/nix-config)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Built with Nix](https://img.shields.io/badge/built%20with-Nix-5277C3.svg?logo=nixos&logoColor=white)](https://nixos.org)

A single Nix flake that manages complete, reproducible system configurations across a small aarch64-only fleet and one container image. There is one source of truth for everything — packages, dotfiles, services, and system settings — and per-platform differences live in composable modules rather than ad-hoc shell scripts.

## What it manages

| Host | Type | System | Machine | Role |
|------|------|--------|---------|------|
| `macos` | [nix-darwin](https://github.com/LnL7/nix-darwin) | `aarch64-darwin` | Apple Silicon Mac | Client only — no remote/incoming traffic |
| `nixpi` | NixOS | `aarch64-linux` | Raspberry Pi 4 | **LIVE server** — ZTIA SSH (short-lived certs over a Cloudflare Tunnel connector) + Caddy landing page |
| `nixvm` | NixOS | `aarch64-linux` | Headless QEMU/HVF VM on the Mac | The **aarch64-linux CI runner** — no public ingress |
| `devcontainer` | OCI image | `aarch64-linux` + `x86_64-linux` | Dev container (multi-arch manifest, published to GHCR) | — |

User environments are layered on with [Home-Manager](https://github.com/nix-community/home-manager), and the devcontainer image is prebuilt and published to GHCR so it starts with a warm Nix store. This is an **aarch64-only** fleet — there is no x86_64 *host* anywhere. The devcontainer image is the one exception: it is published multi-arch (arm64 + amd64) so it also runs on x86_64 GitHub Codespaces.

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
darwin-rebuild switch --flake .#macos   # macOS (Apple Silicon) — client only
nixos-rebuild  switch --flake .#nixpi   # Raspberry Pi 4 — the live server
nixos-rebuild  switch --flake .#nixvm   # UTM/QEMU sandbox VM
```

### Bring up the sandbox VM

`nixvm` runs as a headless QEMU/HVF process managed by a launchd daemon on the Mac
(`services.nixvm-qemu` — `modules/darwin/nixvm-qemu.nix`), no UTM and no GUI. It's provisioned
with `nixos-anywhere`; see the `nixvm-qemu-provision` skill under `.claude/skills/` and
[`docs/nixvm-qemu-runbook.md`](./docs/nixvm-qemu-runbook.md) for the full flow.

For a throwaway graphical VM (XFCE in a native QEMU window; needs a Linux builder):

```bash
nix run .#nixvm-gui
```

### Use the devcontainer

The devcontainer image is prebuilt and published — pull it directly:

```bash
docker pull ghcr.io/kattakath/devcontainer:latest
```

Or just open the repo in a devcontainer-aware editor; `.devcontainer/devcontainer.json` references the same published image.

## Repository layout

```
flake.nix       Entry point: inputs, darwin/nixos configurations, packages, devShells, checks
flake.lock      Pinned input revisions (bumped via `nix flake update`, never hand-edited)
treefmt.nix     Single source of truth for formatting + lint (drives nix fmt, CI, and the hook)
hosts/          Per-host entry profiles (macos.nix, nixpi.nix, nixvm.nix, +installers)
modules/        Reusable modules, split by platform (darwin/ linux/ nixos/ shared/)
packages/       Nix-built artifacts (devcontainer image, nixvm bootstrap, key-recovery kit, landing page)
.claude/        Repo-local Claude Code agents, commands, hooks, skills, and rules
```

Platform branching lives in `modules/` behind `lib.mkIf`, so host profiles stay declarative and platform-agnostic.

## How CI works

CI runs on **GitHub Actions** ([`nix-ci.yml`](./.github/workflows/nix-ci.yml)) across both target systems — `aarch64-darwin` and `aarch64-linux` — on **native**, one-per-system GitHub-hosted runners (`macos-latest`, `ubuntu-24.04-arm`; no QEMU). Each leg does two things: it *builds* the flake's lint/format `checks` (`treefmt` + `pre-commit` — the same derivations `nix fmt` and the commit hook run locally) with [`nix-fast-build`](https://github.com/Mic92/nix-fast-build), and it *evaluates* each host config's toplevel `drvPath` (a full module-system eval that catches config/type errors in seconds) **without building it** — the expensive toplevel builds (notably the Pi SD image) are a release-time concern. Built check results are pushed to the [Cachix](https://www.cachix.org/) (`kattakath`) cache consumed read-only by every host. Branch protection requires the aggregate `required-checks` job.

- [`build-devcontainer`](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml) builds, smoke-tests, and publishes the multi-arch (arm64 + amd64) devcontainer image to GHCR as a manifest list.
- [`build-installers`](https://github.com/kattakath/nix-config/actions/workflows/build-installers.yml) builds and publishes the `nixvm`/`nixpi` installer images to a rolling pre-release.
- [`gitleaks`](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml) scans every push and PR (and weekly) for leaked secrets.
- [`flakehub-publish`](https://github.com/kattakath/nix-config/actions/workflows/flakehub-publish.yml) publishes each push to `main` as a rolling release to [FlakeHub](https://flakehub.com/flake/kattakath/nix-config) via [`flakehub-push`](https://github.com/DeterminateSystems/flakehub-push). Auth is OIDC (`id-token: write`) — no long-lived token. Per FlakeHub's [trusted-platform model](https://docs.determinate.systems/flakehub/publishing/), flakes publish only from CI, never ad-hoc from a laptop.

## Secrets

No plaintext secrets live in this repo. System/service credentials are committed **encrypted** with [agenix](https://github.com/ryantm/agenix) (`secrets/*.age`, recipients declared in `secrets/secrets.nix`) and decrypted at activation into `/run/agenix/` using each host's own SSH host key — today `nixpi`'s Cloudflare Tunnel connector token and the `macos` + `nixvm` GitHub Actions runner PATs. Personal tokens stay out of Nix and git entirely (macOS Keychain / CLI logins). The Cachix substituter is public and read-only (URL + public key, no token). See [SECURITY.md](./SECURITY.md) for the full model.

## Contributing

Contributions and issues are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md) for the workflow and the git-purity rule, and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE) © 2026 Ismail Kattakath
