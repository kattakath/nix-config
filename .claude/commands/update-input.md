---
description: Bump a flake input, stage the regenerated flake.lock, and re-evaluate across all target systems.
argument-hint: "[input]  # optional: nixpkgs | home-manager | ... (empty = all inputs)"
allowed-tools: Bash(nix flake update:*), Bash(git add:*), Bash(git diff:*), Agent(platform-compiler)
---

Update a flake input safely. `$ARGUMENTS` is the input name (e.g. `nixpkgs`, `home-manager`); if empty, update all inputs.

1. Run `nix flake update $ARGUMENTS` (or `nix flake update` if no argument) to regenerate `flake.lock`.
2. Show `git diff flake.lock` so the revision change is reviewable.
3. `git add flake.lock` — the lock must be staged before evaluation (git purity).
4. Delegate to `platform-compiler` to confirm the bump still evaluates on `aarch64-darwin`, `x86_64-linux`, and `aarch64-linux`.
5. If any system breaks, report the failure and recommend reverting `flake.lock` rather than activating. Do NOT run `home-manager switch`.
