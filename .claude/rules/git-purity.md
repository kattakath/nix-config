---
description: Enforces Nix flake git purity — newly generated .nix files must be git-staged before any evaluation pass.
globs:
  - "**/*.nix"
  - "flake.lock"
alwaysApply: true
---

# Git Purity — Stage Before You Evaluate

Nix flakes evaluate the **git tree**, not the working directory. A `.nix` file that has
not been `git add`ed is invisible to the evaluator. Skipping this step produces confusing
`path does not exist` / `error: getting status of ...` failures and stale evaluations
that silently use a previous version of a file.

## Mandatory automation

1. **Before every evaluation pass** (`nix flake check`, `nix flake show`, `home-manager build`,
   `nix-instantiate`), run:

   ```bash
   git add -A
   ```

   or, to stage only the relevant files:

   ```bash
   git add <new-or-changed>.nix flake.nix flake.lock
   ```

2. **Immediately after creating or editing any `.nix` file**, stage it — do not wait until
   evaluation time. The `PostToolUse` hook auto-stages `.nix` writes as a safety net, but you
   must not rely on it alone: explicitly `git add` when you author files in a batch.

3. **After `nix flake update`**, stage the regenerated `flake.lock` before re-evaluating.

4. **Never** run `nix flake check` while `git status` shows untracked `.nix` files — the result
   is not trustworthy. Run `git status` first; if untracked `.nix` files exist, stage them.

## Quick check

```bash
git status --porcelain '*.nix'   # must be empty (or all staged) before evaluation
```

If this command lists any `??` (untracked) `.nix` entries, run `git add -A` before continuing.
