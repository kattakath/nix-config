# nix-config

<!-- CI. nix-ci runs on every push to main (the default landing lane), so its badge follows
     push runs on main. -->
[![nix-ci](https://github.com/kattakath/nix-config/actions/workflows/nix-ci.yml/badge.svg?branch=main&event=push)](https://github.com/kattakath/nix-config/actions/workflows/nix-ci.yml?query=branch%3Amain+event%3Apush)
[![gitleaks](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/kattakath/nix-config/actions/workflows/gitleaks.yml)
[![warm-nixpi-cache](https://github.com/kattakath/nix-config/actions/workflows/warm-nixpi-cache.yml/badge.svg)](https://github.com/kattakath/nix-config/actions/workflows/warm-nixpi-cache.yml)
[![build-devcontainer](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml/badge.svg)](https://github.com/kattakath/nix-config/actions/workflows/build-devcontainer.yml)
<!-- Live status from healthchecks.io: the Pi's dead man's switch, and this repo's scheduled jobs. -->
[![nixpi heartbeat](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F528186e9-b02b-4c28-ae0e-64e2f1%2F-EhhE_KW%2Fnixpi.shields&label=nixpi%20heartbeat)](#monitoring)
[![scheduled jobs](https://img.shields.io/endpoint?url=https%3A%2F%2Fhealthchecks.io%2Fbadge%2F528186e9-b02b-4c28-ae0e-64e2f1%2FNK2O36pY%2Fnix-config.shields&label=scheduled%20jobs)](#monitoring)
[![FlakeHub](https://img.shields.io/endpoint?url=https://flakehub.com/f/kattakath/nix-config/badge)](https://flakehub.com/flake/kattakath/nix-config)
[![License](https://img.shields.io/github/license/kattakath/nix-config)](./LICENSE)

> One declarative Nix flake for an aarch64 fleet: a nix-darwin Mac, a Raspberry Pi server, NixOS VMs and a devcontainer.

Packages, dotfiles, services and system settings all come from this one flake. Platform
differences live in composable modules, never in ad-hoc shell. User environments layer on with
[Home Manager](https://github.com/nix-community/home-manager). Every host is aarch64; the
devcontainer image is the one multi-arch output, so it also runs on x86_64 Codespaces.

## Table of contents

- [Security](#security)
- [Background](#background)
- [Install](#install)
- [Usage](#usage)
- [How CI works](#how-ci-works)
- [Monitoring](#monitoring)
- [Contributing](#contributing)
- [License](#license)

## Security

No plaintext secret lives in this repo: the Nix store is world-readable. Service credentials
are committed encrypted with [agenix](https://github.com/ryantm/agenix); personal tokens stay
in the macOS login Keychain.

- How to report a vulnerability, and the secrets model: [SECURITY.md](./SECURITY.md).
- The mechanism behind each secret: [`docs/secrets-and-keychain.md`](docs/secrets-and-keychain.md).

## Background

The hosts, packages and apps this flake exports are listed in the generated inventory,
[`docs/map/entry-points.md`](docs/map/entry-points.md). The architecture, path by path, starts
at [`docs/repo-map.md`](docs/repo-map.md).

- **`claude/`** is content this repo installs into the operator's home.
- **`.claude/` and `CLAUDE.md`** configure agent sessions working in this repo.

## Install

### Bootstrap a Mac

A new or freshly reset Mac has no Nix yet. The zero-dependency [`bootstrap.sh`](./bootstrap.sh)
installs Determinate Nix, clones the flake, checks your login against the flake's `loginName`
and activates `#macos`:

```bash
# Dry run: reports what it would do, changes nothing. Run it first on a reset Mac.
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash -s -- --check

# Real run:
curl -fsSL https://raw.githubusercontent.com/kattakath/nix-config/main/bootstrap.sh | bash
```

After that first activation, every rebuild is a bare `activate`. It does **not** manage SSH
keys. The full walk-through, including a Mac whose old key is gone:
[`docs/new-mac-runbook.md`](docs/new-mac-runbook.md).

### Fork this for your own fleet

Start a consumer flake with `nix flake init -t github:kattakath/nix-config`, or fork the repo
and set your own identity. Both paths, and the trust model of `curl | bash`:
[`docs/how-to/fork-this-fleet.md`](docs/how-to/fork-this-fleet.md).

### Use the devcontainer

```bash
docker pull ghcr.io/kattakath/devcontainer:latest
```

Or open the repo in a devcontainer-aware editor: `.devcontainer/devcontainer.json` references
the same published image.

## Usage

Everything below assumes [Nix with flakes enabled](https://nixos.org/download).

```bash
git add -A && nix flake check   # The test suite. Flakes only see tracked files, so stage first.
nix develop                     # Dev shell: nixd, treefmt, home-manager (no git hooks).
nix fmt                         # Format + lint-fix every .nix file via treefmt.
nix flake show                  # List every exported configuration and package.
```

### Activate a host

```bash
activate                                     # macOS: a self-elevating darwin-rebuild switch
nix run github:kattakath/nix-config#macos    # macOS FIRST activation only, before `activate` exists
nix develop -c deploy --targets .#nixpi      # Raspberry Pi: builds HERE, activates THERE, and
                                             # rolls itself back if the Pi becomes unreachable
```

The Pi never builds: CI warms its closure in Cachix, and the Mac substitutes it. Every
activation form, and why: [`docs/map/hosts.md`](docs/map/hosts.md).

### Bring up the dev VM

```bash
nix run .#nixvm   # a headless VM; SSH on 127.0.0.1:2222
```

Its root disk **persists** between boots; only the Nix store image is rebuilt. Where the disk
lives and how to reset it: [`docs/map/hosts.md`](docs/map/hosts.md).

## How CI works

- **Changes land by a direct push to `main`.** `nix-ci` runs the full linux suite on that push,
  behind one aggregate `gate` job, and the `ci-watch` plugin reports only failures.
- **Bot and fork PRs** run the same suite and merge through a merge queue.
- **The darwin leg** runs only on PRs and is advisory; `activate` is the darwin check.
- **Each leg builds the flake's `checks`.** The linux leg also evaluates every host toplevel,
  `macos` included, without building it.
- **Publishing:** `warm-nixpi-cache` pushes the Pi's closure to Cachix, `build-devcontainer`
  publishes the image to GHCR, `build-installers` publishes the Pi's SD image, and
  `flakehub-publish` releases each push to `main` to
  [FlakeHub](https://flakehub.com/flake/kattakath/nix-config) over OIDC.

Every workflow, job and required check: [`docs/map/ci.md`](docs/map/ci.md).

## Monitoring

Silence is the alarm. Every scheduled job pings a [healthchecks.io](https://healthchecks.io)
check declared in Nix (`fleet.heartbeats`), and a missed or failed ping emails the operator.

- **nixpi heartbeat** is the Pi's dead man's switch: it pings only while the public site serves.
- **scheduled jobs** covers this repo's own scheduled workflows.

Metrics and logs go to Grafana Cloud:
[`docs/observability-hub-adr.md`](docs/observability-hub-adr.md).

## Contributing

Issues and contributions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md) for the
workflow, and the org-wide
[Code of Conduct](https://github.com/kattakath/.github/blob/main/.github/CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE) © 2026 Ismail Kattakath
