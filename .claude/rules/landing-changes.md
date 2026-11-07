# Landing a change — push to `main`, `ci-watch` reports failures

Unscoped on purpose, like `pr-title.md`: it governs the END of every session, whatever the
session touched. **The procedure lives in the global `claude/CLAUDE.md` § Landing on the
fleet** (direct push, the two leak gates, `ci-watch`, fix forward). This file holds only
what is specific to THIS repo. A session with no installed global context (devcontainer,
Codespaces) gets the procedure from the `ci-watch` plugin's skill, `kattakath/skills`
`plugins/ci-watch`.

## What CI runs on a push to `main`

`nix-ci.yml` has a `push: branches: [main]` trigger (2026-11-07), so a direct push gets the
**full linux suite**: `legs`, `build (aarch64-linux)`, `gitleaks` and `cclint`, behind the
`gate` job. The publish workflows (`warm-nixpi-cache`, `flakehub-publish`, `build-*`)
run on the same push. `ci-watch` waits on all of them.

- **Push runs are keyed on the sha** in `concurrency`. With a ref key, a newer push would
  cancel the older one's pending run (one pending slot per group), and the watcher would
  report a false `RED (cancelled)`.
- **No darwin CI leg on this lane.** `build-darwin` runs only on PRs, so **`activate` is the
  darwin check**. Run it after a push that touches `darwinConfigurations`.
- **Bot PRs now run nix-ci twice**: once in the merge queue, once on the push to `main`.
  That cost is accepted.

## The local check before pushing

The global rule says to check only what you touched. In this repo that means:

| Touched | Run before pushing |
|---|---|
| any `.nix` | `git add -A`, then `nix fmt` (or `nix build .#checks.<system>.formatting`) |
| a host or module | the output you changed, e.g. `nix build --no-link .#darwinConfigurations.macos.system` |
| `.claude/hooks/**` | that hook's `.claude/hooks/tests/*.sh` |
| `CLAUDE.md` | `wc -c CLAUDE.md`, which must stay under 40,000 bytes (`claude-md-budget`) |

Then the two leak gates from the global rule: `nix develop -c gitleaks git
--log-opts="origin/main..HEAD" --redact --no-banner`, plus the client-literal patterns.

## Repo-specific traps

- **The main checkout's branch is what `activate` builds.** Push from a worktree, then
  `git -C <main checkout> merge --ff-only origin/main` before `activate`. Otherwise the
  activation builds the old commit and the fix reads as FAILED.
- **Workflow edits need SSH:** `git push git@github.com:kattakath/nix-config.git HEAD:main`.
  The `origin` remote is HTTPS, and the gh token has no `workflow` scope.
- **nixpi:** never deploy before `warm-nixpi-cache` is green for the pushed sha, or the Mac
  plans a local build (`docs/map/hosts.md`). The Pi itself never builds (Rule 1d).
- **A worktree-isolated session's Bash guard** refuses some gate commands as unprovable git
  (measured 2026-10-18). Never word around the guard. If the leak gates can't run, don't push.
  Tell Ismail instead.
