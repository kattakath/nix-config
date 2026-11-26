# ADR-015 — One shared devcontainer image for the fleet

**Status:** **DECIDED 2026-11-26** (the operator chose each point click-to-select). The image
side has shipped in nix-config; no other fleet repo consumes it yet.

**Question.** nix-config publishes a devcontainer image. Should the other fleet repos use it
instead of building their own, how should they pin it, and how does a repo add tools or
services such as a database?

## 1. Verdict

- **One shared, prebuilt image; every repo points at it.** This is the pattern
  devcontainers/images uses: one base, many consumers, each consumer a single
  `devcontainer.json`.
- **Consumers pin the major tag, `:1`.** nix-config itself keeps `:latest`. A breaking change
  ships as `:2`, on purpose.
- **Extend in this order:** the consumer's own flake devShell for tools; Docker Compose for
  services; a Dockerfile `FROM` the image only as a last resort.
- **The image and the public cache carry nothing non-redistributable.** claude-code reaches a
  container through `nix develop`, downloaded from Anthropic.

## 2. The published image

| Property | Value | Where it is enforced |
|---|---|---|
| Registry | `ghcr.io/kattakath/devcontainer`, **public** (anonymous pull) | org package policy + package setting, recorded in `infra/github/stack.nix` |
| Arches | one index over `linux/arm64` + `linux/amd64` | `build-devcontainer.yml` `manifest` job, pull-verified per platform |
| Tags | `:<sha12>` (immutable), `:latest`, `:1` | same job |
| Settings | `devcontainer.metadata` label: `remoteUser`, `updateRemoteUserUID`, `overrideCommand`, `init` | `packages/devcontainer-image.nix` |
| Tested as a devcontainer | `devcontainer up` + `exec` per arch before any push | `build-devcontainer-impl.yml` |
| Provenance | SLSA v1, `gh attestation verify oci://ghcr.io/kattakath/devcontainer:latest -R kattakath/nix-config` | `actions/attest` in `manifest` |
| Size | contents closure 578.2 MiB (was 1177.6 MiB with claude-code and full git) | measured 2026-11-26 |
| Licensing | no package whose nixpkgs license says `redistributable = false` | `checks.<system>.ci-closures-redistributable`, `cachix-push-filters` |
| Retention | newest 5 publishes plus whatever `:latest`/`:1` point at | `prune-devcontainer.yml` |

## 3. A consumer repo

The minimal form, and the recommended one:

```jsonc
{
  "name": "<repo>",
  "image": "ghcr.io/kattakath/devcontainer:1",
  "workspaceFolder": "/workspaces/<repo>",
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspaces/<repo>,type=bind",
  "postStartCommand": "git config --global --add safe.directory ${containerWorkspaceFolder}"
}
```

- The user, the entrypoint that starts the Nix daemon, and `init` come from the image label.
- `postStartCommand` is needed whenever the host UID is not 1000 (Linux hosts, CI runners).
  The image's own CI test found that on 2026-11-26.
- `hostRequirements` belongs here, not in the label: Codespaces sizes the machine before it
  pulls the image.

**Tools.** A repo with a flake adds its own `devShells.default`; `nix develop` then layers it
on the image's warm store. Every repo, flake or not, can enter nix-config's lean shell for
what the image cannot carry (claude-code): `nix develop github:kattakath/nix-config#fleet`.
It exists for the image's two systems only, and CI enters it inside the container on every
publish. To make it a terminal, add a profile whose command is
`bash -lc "exec nix develop github:kattakath/nix-config#fleet -c claude"`.

**Services (a database).** Use the spec's Docker Compose form: `dockerComposeFile` plus
`service` in `devcontainer.json`. The dev service uses this image; the database is its own
service in the compose file. VS Code, Codespaces and the devcontainers CLI all support it.

**A Dockerfile** (`build.dockerfile`, `FROM ghcr.io/kattakath/devcontainer:1`) works, and
is the last resort: it moves the build back into each repo, the cost this ADR removes.
Devcontainer **Features** are usually written for distribution images with a package
manager; this Nix image has none. Judgment, not tested: expect most Features to fail here.

## 4. Alternatives that lost

| Option | Why it lost |
|---|---|
| Each repo builds its own image | A build per repo, and the copies drift (ADR-014: a second copy is a bug) |
| Consumers on `:latest` | One bad publish reaches every repo's Codespaces at once |
| Pin by digest, bumped by a bot | Needs a write-back bot (ADR-012 § 5 rejected one); Dependabot's `devcontainers` ecosystem tracks Features, not the image |
| Bake claude-code into the image | nixpkgs marks it `redistributable = false`; a public image or cache would redistribute it |
| A private image with per-repo grants | Works and is reversible, but forks and outside contributors cannot pull it |
| nix2container instead of `dockerTools` | Measured 2026-11-26: the push it would shorten takes 35 s per arch, so ~30 s per publish at best. It relocates our ~40 lines of image setup (`copyToRoot` + `perms`) rather than removing them. Popular (949 stars, devenv builds on it) and maintained (v1.1.0, 2026-09-24), but one maintainer wrote 69% of its commits and 36 PRs are open. Nix's own official image and Determinate's use `dockerTools.buildLayeredImageWithNixDb` for this exact job. **Reopen when** repos build derived images (`fromImage` layer reuse), the push passes ~2 min, or the maintainer share drops below half |

## 5. Weakest assumptions

- **`:1` will rarely need to move.** Nothing yet defines "breaking" in a checkable way. The
  first candidate: a change to the label's `remoteUser`, or to a path a consumer mounts.
- **Codespaces honours `workspaceMount`.** The Codespaces docs fetched on 2026-11-26 do not
  say. It works today only because the repo name matches `/workspaces/<repo>`.
