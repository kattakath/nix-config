---
description: Stage all .nix files then evaluate the flake across both target systems.
argument-hint: "[config]  # optional: macos | nixpi | nixvm"
allowed-tools: Bash(git add:*), Bash(git status:*), Bash(nix flake check:*), Bash(nix eval:*)
---

Run the canonical evaluation gate for this Nix mono-repo, in order:

1. **Git purity** — run `git add -A`, then `git status --porcelain '*.nix'` to confirm no untracked `.nix` files remain. Flakes ignore untracked files, so this MUST happen before evaluation.
2. **Cross-platform evaluation** — run `nix flake check` to evaluate every flake output across `aarch64-darwin` and `aarch64-linux`. To scope to a single host, evaluate its toplevel directly, e.g. `nix eval .#darwinConfigurations.macos.config.system.build.toplevel.drvPath` (or `.#nixosConfigurations.<nixpi|nixvm>.config.system.build.toplevel.drvPath`).
3. **Report** — relay the per-system pass/fail result and a clear `READY` / `BLOCKED` verdict. If `nix` is unavailable locally, state clearly that results are syntax-only (`nix-instantiate --parse` where possible) and full evaluation is CI-deferred to GitHub Actions (see `.github/workflows/nix-ci.yml`).

$ARGUMENTS may name a single config (e.g. `macos`, `nixpi`, `nixvm`) to scope the evaluation.
