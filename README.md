# nix-config

> One declarative Nix flake for my aarch64 fleet — my Mac, a Raspberry Pi server, a throwaway dev VM, and a prebuilt devcontainer.

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
| `nixpi` | NixOS | `aarch64-linux` | Raspberry Pi 4 | **LIVE server** — static-key SSH over a Cloudflare Tunnel connector + Caddy landing page |
| `nixvm` | NixOS | `aarch64-linux` | Throwaway QEMU dev VM on the Mac | Ephemeral XFCE desktop via `nix run .#nixvm` — not installed |
| `devcontainer` | OCI image | `aarch64-linux` + `x86_64-linux` | Dev container (multi-arch manifest, published to GHCR) | — |

User environments are layered on with [Home-Manager](https://github.com/nix-community/home-manager), and the devcontainer image is prebuilt and published to GHCR so it starts with a warm Nix store. This is an **aarch64-only** fleet — there is no x86_64 *host* anywhere. The devcontainer image is the one exception: it is published multi-arch (arm64 + amd64) so it also runs on x86_64 GitHub Codespaces.

## Bootstrap or recover a Mac (the first thing on a clean machine)

On a new or freshly-reset Mac there is no Nix yet, so a single zero-dependency script
([`bootstrap.sh`](./bootstrap.sh)) does the irreducible minimum — installs Determinate
Nix, then hands off to the flake. Run it straight from the repo over TLS, like
Determinate's own installer (it **auto-detects** an iCloud recovery kit):

```bash
# Dry run — reports exactly what it would do, changes nothing:
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash -s -- --check

# Real run:
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash
```

It clones the flake, verifies your macOS login equals the flake's `userName` (hard-fails
with fork instructions if not), then:

- **recovery kit present** (`~/Library/Mobile Documents/com~apple~CloudDocs/nix-key-recovery`,
  published beforehand by `nix run .#key-backup`) → restores your operator key, re-keys
  agenix to this Mac's new host key, activates `#macos`;
- **no kit** → **founds** a brand-new operator identity (a fresh keypair, agenix re-keyed
  to it), then activates `#macos`. Afterward: register `~/.ssh/id_ed25519.pub` on GitHub
  (auth + signing) and `nix run .#key-backup`. Add `--fresh` to skip the confirmation on a
  headless box.

Prefer not to trust the raw URL? The kit ships the same (CI-linted) `bootstrap.sh` — run the
on-disk copy, `./bootstrap.sh`. (It still needs network: it downloads the Determinate
installer and `nix run`s the flake — it is not fully offline.)

### Fork this for your own fleet

This is personal config with `userName = "ismailkattakath"` baked into `flake.nix` (it is
your POSIX account — `/Users/<userName>` and `home-manager.users.<userName>`). To run your
own fleet from it:

1. **Fork** the repo on GitHub.
2. In `flake.nix`, set `userName` to **your macOS login** (`id -un`), and set `orgName` /
   `handleName` / `domainName` to your own. Commit and push. (Running the offline copy? Also
   set `FLAKE_DEFAULT` in `bootstrap.sh`.)
3. On your fresh Mac, run **pointing at your fork**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/<you>/nix-config/main/bootstrap.sh \
     | bash -s -- --flake=github:<you>/nix-config
   ```

   With no kit it **founds your own keys** and activates `#macos`.

The `userName` guard is what makes this safe: if your login does not match the flake's
`userName`, bootstrap stops **before** activating and tells you to fork and set `userName` —
rather than half-activating home-manager for a user that does not exist.

> **Trust model.** You are piping remote code into `bash`, and it uses `sudo`. The anchor is
> the repo over TLS from `raw.githubusercontent.com` (**your own fork**, in the fork flow —
> pin a commit SHA in place of `/main/` for a stronger guarantee). `bootstrap.sh` is the exact
> bytes CI shellchecks (the `key-recovery-bootstrap` derivation) and that `nix run .#key-backup`
> publishes into the kit; a truncated download runs nothing (it is brace-guarded). **No secret
> transits the pipe** — passphrases are read from `/dev/tty`, `osascript` is only ever used for
> notices, and privilege escalation goes through `sudo` / Touch ID. Founding mode mints a **new**
> identity: old service-secret contents are unrecoverable (and revocable).

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
```

### Bring up the dev VM

`nixvm` is not installed anywhere — it exists only as a throwaway graphical VM (XFCE in a
native QEMU window on macOS, no UTM, booted from a fresh overlay each time):

```bash
nix run .#nixvm
```

Its `aarch64-linux` guest builds locally on Determinate's native Linux builder (or
substitutes from Cachix), so no provisioning, builder VM, or self-hosted runner is involved.

### Use the devcontainer

The devcontainer image is prebuilt and published — pull it directly:

```bash
docker pull ghcr.io/kattakath/devcontainer:latest
```

Or just open the repo in a devcontainer-aware editor; `.devcontainer/devcontainer.json` references the same published image.

## Repository layout

```
bootstrap.sh    No-Nix curl entrypoint: install Determinate Nix, then hand off to the flake
flake.nix       Entry point: inputs, darwin/nixos configurations, packages, devShells, checks
flake.lock      Pinned input revisions (bumped via `nix flake update`, never hand-edited)
treefmt.nix     Single source of truth for formatting + lint (drives nix fmt, CI, and the hook)
hosts/          Per-host entry profiles (macos.nix, nixpi.nix, nixvm.nix)
modules/        Reusable modules, split by platform (darwin/ linux/ nixos/ shared/)
packages/       Nix-built artifacts (devcontainer image, key-recovery kit, landing page)
.claude/        Repo-local Claude Code agents, commands, hooks, skills, and rules
```

Platform branching lives in `modules/` behind `lib.mkIf`, so host profiles stay declarative and platform-agnostic.

## How CI works

CI runs on **GitHub Actions** ([`nix-ci.yml`](./.github/workflows/nix-ci.yml)) across both target systems — `aarch64-darwin` and `aarch64-linux` — on **native**, one-per-system GitHub-hosted runners (`macos-latest`, `ubuntu-24.04-arm`; no QEMU). Each leg does two things: it *builds* the flake's lint/format `checks` (`treefmt` + `pre-commit` — the same derivations `nix fmt` and the commit hook run locally) with [`nix-fast-build`](https://github.com/Mic92/nix-fast-build), and it *evaluates* each host config's toplevel `drvPath` (a full module-system eval that catches config/type errors in seconds) **without building it** — the expensive toplevel builds (notably the Pi SD image) are a release-time concern. Built check results are pushed to the [Cachix](https://www.cachix.org/) (`kattakath`) cache consumed read-only by every host. Branch protection requires the aggregate `required-checks` job.

- [`build-devcontainer`](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml) builds, smoke-tests, and publishes the multi-arch (arm64 + amd64) devcontainer image to GHCR as a manifest list.
- [`build-installers`](https://github.com/kattakath/nix-config/actions/workflows/build-installers.yml) builds and publishes the `nixpi` SD image to a rolling pre-release.
- [`gitleaks`](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml) scans every push and PR (and weekly) for leaked secrets.
- [`flakehub-publish`](https://github.com/kattakath/nix-config/actions/workflows/flakehub-publish.yml) publishes each push to `main` as a rolling release to [FlakeHub](https://flakehub.com/flake/kattakath/nix-config) via [`flakehub-push`](https://github.com/DeterminateSystems/flakehub-push). Auth is OIDC (`id-token: write`) — no long-lived token. Per FlakeHub's [trusted-platform model](https://docs.determinate.systems/flakehub/publishing/), flakes publish only from CI, never ad-hoc from a laptop.

## Secrets

No plaintext secrets live in this repo. The one committed secret — `nixpi`'s Cloudflare Tunnel token — is encrypted with [agenix](https://github.com/ryantm/agenix) (`secrets/cloudflared-token.age`, recipient declared in `secrets/secrets.nix`) to the **operator's key alone**, so agenix is effectively an **operator-only vault**: the operator decrypts it on the Mac and plants it on the SD card's FAT `FIRMWARE` partition, from where it is copied into a `/run` file at boot — it is **never** decrypted on `nixpi` (a fresh SD flash rotates the host key, which would break host-key decryption and kill the only remote path in). No secret is host-decrypted into `/run/agenix/` anymore, and there are no runner PATs — the fleet's self-hosted runners are retired and CI is fully GitHub-hosted. Personal tokens stay out of Nix and git entirely (macOS Keychain / CLI logins). The Cachix substituter is public and read-only (URL + public key, no token). See [SECURITY.md](./SECURITY.md) for the full model.

## Contributing

Contributions and issues are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md) for the workflow and the git-purity rule, and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE) © 2026 Ismail Kattakath
