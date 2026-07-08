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

## PR title

The PR title is a **comma-separated list of the components the change touches**,
not a prose sentence. As a consolidated PR grows, keep the title in sync with the
combined scope. Each component is derived — don't consult a fixed enumeration,
apply the rule:

1. **A first-level `nix flake show` output category** when the change touches a
   flake output — e.g. `apps`, `checks`, `packages`, `nixosConfigurations`,
   `darwinConfigurations`, `formatter`, `devShells`. This is a **semantic** map
   from source path to output (`modules/darwin/*` → `darwinConfigurations`,
   `hosts/nixpi*` → `nixosConfigurations`, `packages/*` → `packages`, and so on),
   so it needs judgment and a maintained path→output mapping.
2. **A top-level directory named by stripping its leading dot** — `.claude` →
   `claude`, `.github` → `github`, `.vscode` → `vscode`, `.devcontainer` →
   `devcontainer`, and so on. These mappings are **illustrative, not exhaustive**:
   ANY top-level dot-folder maps to its own de-dotted name automatically, so a new
   one needs no edit to this rule. (`docs` also falls here, covering `docs/`, any
   `*.md`, and `CLAUDE.md`.)

List every touched component, comma-separated. Example: a PR touching
`modules/darwin/*` + `.claude/rules/*` + `docs/` → title `darwinConfigurations, claude, docs`.

**Note the asymmetry.** The dot-folder half (2) is **mechanically** derivable from
the path — strip the dot — so a hook could generate it automatically. The
flake-output half (1) is a **semantic** mapping requiring judgment against a
maintained path→output map, which a hook could not derive reliably. That is why
this stays a prompt rule rather than a fully mechanical one.

## Update comment trail

Every time an already-open PR is **updated** — i.e. each push of new commits onto
its branch — post a **new** PR comment summarizing that update's changes:

```bash
gh pr comment <n> --body "<what this push changed and why>"
```

The comment is posted at **push time** (that is when the PR actually updates). The
PR's comment thread thus becomes a chronological trail of every mutation batched
into the consolidated PR: reading the comments top-to-bottom tells you what changed
and when, keeping the one-PR-per-session model auditable.

Optional enhancement: also maintain a running `## Changelog` in the PR **body**,
edited each update (the body reflects the *current* combined state; the comments are
the *chronological* trail). The per-update comment is the required part; the body
changelog is a nicety.

## Quick check

```bash
gh pr list --author "@me" --state open   # any open PR from this session already?
git branch --show-current                 # confirm you're on that PR's branch before committing
```

If the only open PR is already merged (`gh pr view <n> --json state` shows
`MERGED`), start a new branch off latest `main` for the next change.
