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

Every PR is built by [Garnix](https://garnix.io) (configured in `garnix.yaml`), which builds the flake's outputs on native builders across all three canonical systems (`aarch64-darwin`, `x86_64-linux`, `aarch64-linux`) — reporting one status check per output, including the host configs (`darwinConfig nixcon`, `nixosConfig nixbox`, `nixosConfig nixrpi`), the flake eval (`Evaluate flake.nix`), and the `treefmt` + `pre-commit` `checks.*`. A change that evaluates cleanly on one platform can still break another, so let CI go green before expecting a review. The `gitleaks` workflow (`Scan for secrets`) also scans for leaked secrets, and `build-devcontainer` verifies the devcontainer image still builds. Branch protection requires the per-config Garnix checks plus `Scan for secrets`.

Keep changes lean and accurate, and never commit secrets (see [SECURITY.md](./SECURITY.md)).
