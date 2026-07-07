# PR Consolidation — One Open PR Per Working Session

Don't fragment a working session's output across multiple small PRs. When a PR is
already open for the current session's work, push follow-up commits onto that
same branch instead of branching off `main` again for the next change.

## Why

This repo's CI builds are expensive (Nix closure builds pushed to Cachix, plus
installer/devcontainer image publishes), and the costliest workflow does **not**
supersede its own in-flight runs. `build-installers.yml` sets its `concurrency`
group to `cancel-in-progress: false`, so a new push does not cancel an already
running installer publish — the runs **queue** and each one completes in full.
(The cheaper workflows — `nix-ci.yml`, `build-devcontainer.yml`, `gitleaks.yml`,
`claude-config-lint.yml` — do set `cancel-in-progress: true` and self-supersede.)
Because of that non-cancellable release workflow, every extra PR or push spawns
another costly pipeline run that piles up rather than replacing the previous one.
Consolidating a session's work onto one open PR avoids triggering redundant
expensive, non-cancellable runs.

## Mandatory behavior

1. **Before opening a new PR**, check whether a PR from earlier in this session is
   still open (`gh pr list`, or recall the branch/PR you already created/pushed to).
2. **If an open PR from this session exists**, commit and push further changes to
   its branch (`git checkout <branch>`, commit, `git push`) rather than creating a
   new branch/PR — even for a change that touches unrelated files. Update the PR
   title/body to reflect the combined scope when the change set grows.
3. **Exception — the existing PR has already merged.** Once a session's PR lands
   on `main`, its branch is done. The next change starts a fresh branch and a new
   PR — do not try to reuse or reopen a merged branch.
4. **Exception — the user explicitly asks for a separate PR** (e.g. to keep an
   unrelated change reviewable on its own). Explicit instruction overrides the
   default.

## Quick check

```bash
gh pr list --author "@me" --state open   # any open PR from this session already?
git branch --show-current                 # confirm you're on that PR's branch before committing
```

If the only open PR is already merged (`gh pr view <n> --json state` shows
`MERGED`), start a new branch off latest `main` for the next change.
