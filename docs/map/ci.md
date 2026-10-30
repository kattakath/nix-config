Part of the [repo map](../repo-map.md) — the full fleet architecture.

## CI, release, publishing

**Some checks exist ONLY on `aarch64-linux`**, so the documented local gate — a bare
`nix flake check`, which is darwin-native on the Mac — never builds them:
`cloudflared-connector-module`, `determinate-daemon-nixpi`, `firmware-secrets-module`
(list them with `nix flake show --json --all-systems`). Every other linux check shares ONE source block with its darwin twin,
so the bare command does exercise those. (`determinate-daemon-nixpi` was named
`determinate-daemon` until 2026-10-18 — the same NAME as the macos contract, which is how it
was miscounted as a twin here.)

Build them locally when you touch what they cover — Determinate's native Linux
builder runs them fine, verified with `--rebuild` so they genuinely executed:

```bash
nix build --no-link .#checks.aarch64-linux.{cloudflared-connector-module,determinate-daemon-nixpi,firmware-secrets-module}
```

**Not** `nix flake check --all-systems` (builds on). It does reach the linux checks —
proven by `checks.aarch64-linux.pre-commit` emitting builder log lines and a non-zero
BUILDER exit — but that check FAILS on the native Linux builder with
`FileNotFoundError` from pre-commit's treefmt hook, for a builder-environment reason,
not a code one. It passes on CI's real `ubuntu-24.04-arm` runner. A gate that cries
wolf is worse than no gate; same class as the caddy `cp --no-preserve=mode` EPERM.

`.github/workflows/nix-ci.yml` — native multi-system Nix CI on GitHub Actions, ALL on
GitHub-**HOSTED** runners (`ubuntu-24.04-arm` for aarch64-linux, `macos-latest` for
aarch64-darwin; both free & unlimited on public repos). Jobs: `flake-checker` (advisory),
`legs` (a parallel VERIFIER), one caller job per leg — `build-linux`, `build-darwin`,
`build-darwin-advisory` — each running the reusable **`nix-ci-impl.yml`**, and the aggregate
`required-checks`. A leg *builds* `.#checks.<system>` (among them `pre-commit` = treefmt **and** a gitleaks scan of the working tree,
`modules/parts/devshell.nix`) with plain `nix build` (enumerated from
the flake, so a NEW check needs no workflow edit; pushed to the `kattakath` Cachix cache —
`nix-fast-build` was dropped 2026-09-22, its own closure was half the darwin leg) and
*evaluates* (no build) host toplevels — this workflow builds none (its own header says so).
nixpi's toplevel is built by `warm-nixpi-cache.yml` instead (below; why:
[`hosts.md`](hosts.md)), and its flashable sdImage by `build-installers.yml`. Check-run names are `build (<system>) / leg`.

**Who waits on what** (2026-10-18, [`pr-wait-research.md`](../pr-wait-research.md) levers
#3 + #4):

| Leg | Required? | Checks | Hosts evaluated |
|---|---|---|---|
| `build (aarch64-linux)` | always | all linux | **every** host, macos included |
| `build (aarch64-darwin)` | push:main, dispatch, **non-operator** PRs | PR: darwin-ONLY (29/52); push: all | PR: none; push: macos |
| `build (aarch64-darwin, advisory)` | never — nothing `needs` it | all | macos |

- **Operator PRs** (author id `8927166`) skip the required darwin job and run the advisory
  twin; `required-checks` accepts `skipped` for darwin **only** under that predicate.
  `author_association == 'OWNER'` was rejected: the repo is **org-owned**, and 96/96 sampled
  operator PRs read `MEMBER`, so an OWNER test never matches. Agent sessions open PRs AS the
  operator, so in practice **every agent PR** gets advisory darwin — only bots stay required.
- **Linux evaluating macos is sound**, on two facts: pure flake eval has no
  `builtins.currentSystem`, and `darwinConfigurations.macos` evaluates with
  `--option allow-import-from-derivation false` (measured 2026-10-18), so no darwin builder is
  needed. A drvPath comparison under `--eval-system aarch64-linux` is NOT evidence — that flag
  only sets what pure eval already hides, so it could not have differed. A real linux evaluator
  confirmed it: run 39127414938's `build (aarch64-linux)` leg evaluated macos green
  (2026-10-18). A red macos eval there is a finding, not flakiness.
- **Name = source, or the PR filter lies.** `system-only` subtracts check NAMES, so it is only
  correct while a name shared across systems comes from ONE source block. A per-host contract
  carries its host in its name: the two Determinate contracts were both `determinate-daemon`
  until 2026-10-18, so every non-operator PR silently skipped the macos one. Census that day:
  23 shared names, each ONE definition site.
- **Residual risk, accepted:** a shared-source check that breaks only on darwin's platform can
  merge from a PR; push:main builds every darwin check, so it goes red right after merge.

**The coverage invariant is SET EQUALITY, verified by `legs`** (since 2026-10-18; derived
2026-09-21 → 10-18). `legs` used to EMIT the build matrix, so every leg `needs:`-queued behind
it — ~45 s in front of darwin in 40/40 runs. Now the legs are written out in `nix-ci.yml` (the
system → `runs-on` lookup is the one fact GitHub owns and the flake cannot answer) and `legs`
checks them **in parallel**, both ways: a host whose system no leg claims HARD-FAILS (*add a
leg job for it*), and so does a leg owning no host. The leg side is read out of `nix-ci.yml`
itself with `yq-go` from the pinned nixpkgs — never restated in bash, which would be the
second copy the job exists to catch. `required-checks` still `needs` it, so it still blocks.

**`nix flake show --json --all-systems` IS the source** for the host side. Its flake-schemas
`inventory` carries `forSystems` per host child, classified by the CONFIGURATION's own system
— measured: `nixosConfigurations.nixpi → ["aarch64-linux"]`, `darwinConfigurations.macos →
["aarch64-darwin"]`. Two degradations are real, and each is a GUARD rather than a reason to
reject: without `--all-systems`, foreign-system children come back `{"filtered": true}`
(measured), so classification would silently follow the RUNNER's arch; and upstream Nix emits
the flat legacy shape with no `inventory` key, which parses to ZERO rows (probed). Both fail
the job loudly. Inside a leg, an empty host list is a hard failure, and the darwin PR leg's
host skip is an explicit, logged `eval-categories: none` — never an empty list falling
through. `required-checks` fails on **`'skipped'`** everywhere else: a skipped job is neither
failure nor cancelled, so without that it could report green over a leg that never ran.

**`checks.<system>.actionlint` runs actionlint inside a PROJECT** (an empty `.git` marker
above a copy of the whole `.github` tree). From a bare store copy it found no project and
silently skipped caller→callee validation of `uses: ./.github/workflows/*-impl.yml` and of the
composite `uses: ./.github/actions/nix-setup` — measured: an undefined input exited 0 there and
failed `[workflow-call]` / `[action]` with the marker.

**No workflow in this repo targets a self-hosted runner** — every leg is GitHub-hosted (fork
PRs need no runner fallback), and day-to-day local aarch64-linux builds use Determinate's
native Linux builder on the Mac. The ruleset's required checks:
[`auto-merge-and-merge-queue.md`](../auto-merge-and-merge-queue.md).

Do **not** read that as "the Mac has no runners": `macos` declares **five** runners — two
bare-metal ephemeral runners on the **`dontsell-ai`** org
(`modules/darwin/github-runner.nix`, [`modules-darwin.md`](modules-darwin.md)), two ephemeral Tart-VM-per-job lanes
(`local.tart.githubRunners.*` — `dontsell-vm`, plus `kattakath` declared `enable = false`), and one GitLab runner
(`local.tart.gitlabRunner`). None of them serve *this* repo's CI. The facts are about different repos.

Also in `.github/workflows/`: `auto-merge.yml`, `build-devcontainer.yml`,
`build-installers.yml`, `claude*.yml`, `gitleaks.yml`, and `flakehub-publish.yml` — the last
publishes each push to `main` as a rolling release to FlakeHub via
`DeterminateSystems/flakehub-push`, authenticated by OIDC/`id-token: write` with **no** stored
token; per FlakeHub's trusted-platform model, flakes publish only from CI, never ad-hoc from a
laptop. Merge mechanics: [`auto-merge-and-merge-queue.md`](../auto-merge-and-merge-queue.md).

**Not every change goes through a PR.** A docs/`.claude`-only change may push straight to
`main` after a local gate; which paths qualify, and the gate, live in ONE place:
[`landing-changes.md`](../../.claude/rules/landing-changes.md) § 2. § 1 of the same file says
how to wait on a PR's CI: in the BACKGROUND, never by polling inside a turn.

Three more, each self-documenting in its header:

- `warm-nixpi-cache.yml` — **keeps the Pi from ever building**: builds nixpi's toplevel on a
  real `ubuntu-24.04-arm` runner and pushes the closure to Cachix on every nixpi-closure change,
  so the Mac and the Pi substitute. Why it matters: [`hosts.md`](hosts.md).
- `update-flake-lock.yml` — the scheduled counterpart to `/update-input`: a weekly
  `nix flake update` PR, opened with a GitHub App token so `nix-ci` actually runs on it, and
  self-arming for auto-merge.
- `arm-dependabot.yml` — a scheduled job that arms auto-merge on open `dependabot[bot]` PRs,
  which had no unattended landing path. Scheduled rather than event-driven because a
  Dependabot-triggered run gets no Actions secrets, so it cannot mint the App token; its header
  records the three rejected one-line alternatives.

