# Contributing

Thanks for your interest. This is a personal Nix mono-repo, but issues and pull requests are welcome.

## Proposing changes

1. Fork or branch off `main`.
2. Make your change in the appropriate place — host profiles in `hosts/`, reusable logic in `modules/` (branch platforms behind `lib.mkIf`, don't duplicate across hosts).
3. Open a pull request describing what changed and why.

## Before you open a PR

Flakes evaluate the **git tree**, not your working directory — an unstaged `.nix` file is invisible to the evaluator and produces confusing errors. Always stage first:

```bash
git add -A          # git purity: stage before evaluating
nix fmt             # format + lint-fix (nixfmt + statix + deadnix)
nix flake check     # evaluate every output + run the lint / pre-commit checks
```

`nix flake check` on your machine only fully evaluates your host's system. That's fine — CI does the rest.

## What CI validates

Every PR runs through **GitHub Actions** (`.github/workflows/nix-ci.yml`), one native leg per target system (`ubuntu-24.04-arm` for `aarch64-linux`, `macos-latest` for `aarch64-darwin`), each a caller of the reusable `nix-ci-impl.yml`. The **linux** leg *builds* every `aarch64-linux` check (pushing them to the `kattakath` Cachix cache) and *evaluates* every host config's toplevel — `macos` included — without building it, enough to catch config/type errors cheaply. On a PR the **darwin** leg builds only the darwin-only checks and evaluates no host; a push to `main` builds every darwin check and evaluates `macos` natively. Darwin is **required** on PRs from anyone but the repo operator (bots, Dependabot, outside contributors) and **advisory** on the operator's own PRs, where a non-gating twin runs the full darwin leg instead. Details: [`docs/map/ci.md`](docs/map/ci.md). A change that evaluates cleanly on one platform can still break the other, so let CI go green before expecting a review. The `gitleaks` workflow (`Scan for secrets`) also scans for leaked secrets, and `build-devcontainer` verifies the devcontainer image still builds. Branch protection requires the aggregate `required-checks` job, `Scan for secrets`, and `Lint .claude config`.

Keep changes lean and accurate, and never commit secrets (see [SECURITY.md](./SECURITY.md)).
