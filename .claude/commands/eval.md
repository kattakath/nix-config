---
description: Stage all .nix files then evaluate the flake across all three target systems via the platform-compiler agent.
argument-hint: "[config]  # optional: nixcon | nixbox | nixrpi"
allowed-tools: Bash(git add:*), Bash(git status:*), Agent(platform-compiler)
---

Run the canonical evaluation gate for this Nix mono-repo, in order:

1. **Git purity** — run `git add -A`, then `git status --porcelain '*.nix'` to confirm no untracked `.nix` files remain. Flakes ignore untracked files, so this MUST happen before evaluation.
2. **Cross-platform evaluation** — delegate to the `platform-compiler` agent to evaluate every flake output across `aarch64-darwin`, `x86_64-linux`, and `aarch64-linux`.
3. **Report** — relay the agent's per-system pass/fail table and final `READY` / `BLOCKED` verdict verbatim. If `nix` is unavailable locally, state clearly that results are syntax-only and full evaluation is CI-deferred to `.github/workflows/flake-check.yml`.

$ARGUMENTS may name a single config (e.g. `nixcon`, `nixbox`, `nixrpi`) to scope the evaluation; pass it through to the agent.
