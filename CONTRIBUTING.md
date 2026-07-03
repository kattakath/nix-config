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

Every PR runs the `flake-check` workflow, which evaluates the flake across all three canonical systems (`aarch64-darwin`, `x86_64-linux`, `aarch64-linux`) plus a `treefmt` + `pre-commit` lint gate. A change that evaluates cleanly on one platform can still break another, so let CI go green before expecting a review. The `gitleaks` workflow also scans for leaked secrets, and `build-devcontainer` verifies the devcontainer image still builds.

Keep changes lean and accurate, and never commit secrets (see [SECURITY.md](./SECURITY.md)).
