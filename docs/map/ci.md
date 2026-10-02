Part of the [repo map](../repo-map.md) — the full fleet architecture.

## CI, release, publishing

**Three checks exist ONLY on `aarch64-linux`**, so the documented local gate — a bare
`nix flake check`, which is darwin-native on the Mac — never builds them:
`cloudflared-connector-module`, `firmware-secrets-module`, `nixpi-firmware-names`
(measured 2026-09-22: 18 linux checks, 41 darwin, 3 linux-only). Every other linux check
has a darwin twin with identical logic, so the bare command does exercise those.

Build the three locally when you touch what they cover — Determinate's native Linux
builder runs them fine, verified with `--rebuild` so they genuinely executed:

```bash
nix build --no-link .#checks.aarch64-linux.{cloudflared-connector-module,firmware-secrets-module,nixpi-firmware-names}
```

**Not** `nix flake check --all-systems` (builds on). It does reach the linux checks —
proven by `checks.aarch64-linux.pre-commit` emitting builder log lines and a non-zero
BUILDER exit — but that check FAILS on the native Linux builder with
`FileNotFoundError` from pre-commit's treefmt hook, for a builder-environment reason,
not a code one. It passes on CI's real `ubuntu-24.04-arm` runner. A gate that cries
wolf is worse than no gate; same class as the caddy `cp --no-preserve=mode` EPERM.

`.github/workflows/nix-ci.yml` — native multi-system Nix CI on GitHub Actions, ALL on
GitHub-**HOSTED** runners (`ubuntu-24.04-arm` for aarch64-linux, `macos-latest` for
aarch64-darwin; both free & unlimited on public repos). The leg COUNT is no longer a fixed 2:
a `legs` job derives the build matrix from the fleet's own host systems (below), so the
workflow's jobs are `flake-checker` (advisory), `legs`, one `build` leg per host system, and
the aggregate `required-checks`. Each build leg *builds*
the lint/format/structural `checks` — `formatting`, `pre-commit`,
`claude-md-budget`, `ast-grep`, `deploy-schema`, `capsule-registry` — with `nix-fast-build` (it globs `.#checks.<system>`, so a NEW check needs no workflow edit;
pushed to the `kattakath` Cachix cache) and
*evaluates* (no build) its host config toplevel(s). Building host toplevels is deferred to
release time (`build-installers`, also hosted).

**BOTH halves of the coverage invariant are DERIVED, not listed** (2026-09-21) — the legs as
well as the hosts each leg evaluates. One `legs` job (on `macos-latest`, because this evaluator
must reach both systems' configurations) emits
`{include:[{name,runs-on,eval-attrs}]}`, which `build` consumes via
`strategy.matrix: ${{ fromJSON(needs.legs.outputs.matrix) }}`. Legs therefore come FROM hosts:
a leg owning **zero** hosts is structurally impossible, and the reachable failure is the
inverse — a HOST no leg claims hard-fails `legs` with *add its runner to this lookup*. Today
that reproduces the old hard-coded lists exactly (aarch64-linux → `nixpi`+`nixvm`,
aarch64-darwin → `macos`), but a host added to `modules/parts/hosts.nix` now either lands on an
existing leg or stops CI until someone names its runner; previously it was silently untested
until someone remembered this file. It runs as ONE job, not a step inside each leg, because the
check needs the whole host→system list that no single leg can see. The ONE hard-coded fact left
is the system → `runs-on` lookup, which GitHub owns and the flake cannot answer.

**`nix flake show --json --all-systems` IS the source.** An earlier claim here that it could
not serve was re-measured and is false, so the off-the-shelf tool was adopted and both
hand-written `--apply` expressions walking `config.nixpkgs.hostPlatform.system` are retired.
Its flake-schemas `inventory` carries `forSystems` per host child, classified by the
CONFIGURATION's own system — measured on aarch64-darwin: `nixosConfigurations.nixpi →
["aarch64-linux"]`, `darwinConfigurations.macos → ["aarch64-darwin"]`. Two degradations are
real, and each is now a GUARD rather than a reason to reject: without `--all-systems`,
foreign-system children come back `{"filtered": true}` (measured), so classification would
silently follow the RUNNER's arch; and upstream Nix emits the flat legacy shape with no
`inventory` key, which parses to ZERO rows (probed). Both fail the job loudly, so a revert to
`cachix/install-nix-action` cannot quietly ship a fleet with no legs. The empty-attrs test
inside a leg survives as the belt to that derivation's braces (`nix-ci.yml:272-275`) and is a
hard failure, never the old `if: matrix.eval-attrs != ''` skip, which made a vacuous leg go
green while testing nothing. `required-checks` accordingly `needs: [legs, build]` and fails on
**`'skipped'`** as well — a failed `legs` does not fail `build`, it SKIPS it, and skipped is
neither failure nor cancelled, so without that the aggregate gate would report green over zero
legs.

**No workflow in this repo targets a self-hosted runner** — every leg is GitHub-hosted (fork
PRs need no runner fallback), and day-to-day local aarch64-linux builds use Determinate's
native Linux builder on the Mac. Branch protection requires the aggregate `required-checks`
job.

Do **not** read that as "the Mac has no runners": `macos` hosts **six** runner lanes — two
bare-metal ephemeral runners on the **`dontsell-ai`** org
(`modules/darwin/github-runner.nix` above), three ephemeral Tart-VM-per-job runners
(`local.tart.githubRunners.*` — `kattakath`, `silvercreek-ai`, `dontsell-vm`), and one GitLab runner
(`local.tart.gitlabRunner`). None of them serve *this* repo's CI. The facts are about different repos.

Also in `.github/workflows/`: `auto-merge.yml`, `build-devcontainer.yml`,
`build-installers.yml`, `claude*.yml`, `gitleaks.yml`, and `flakehub-publish.yml` — the last
publishes each push to `main` as a rolling release to FlakeHub via
`DeterminateSystems/flakehub-push`, authenticated by OIDC/`id-token: write` with **no** stored
token; per FlakeHub's trusted-platform model, flakes publish only from CI, never ad-hoc from a
laptop. Merge mechanics: [`auto-merge-and-merge-queue.md`](../auto-merge-and-merge-queue.md).

