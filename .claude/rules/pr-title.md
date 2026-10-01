# PR Title — Comma-Separated List of Touched Components

The PR title is a **comma-separated list of the components the change touches**,
not a prose sentence. Each component is derived — don't consult a fixed
enumeration, apply the rule:

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

If a PR's scope grows after it is opened, keep the title in sync with the new
combined scope.

**Note the asymmetry.** The dot-folder half (2) is **mechanically** derivable from
the path — strip the dot — so a hook could generate it automatically. The
flake-output half (1) is a **semantic** mapping requiring judgment against a
maintained path→output map, which a hook could not derive reliably. That is why
this stays a prompt rule rather than a fully mechanical one.

## One PR per change

Default GitHub behaviour: **one PR per logical change, branched off `main`.** There
is no session-batching rule — an already-open PR is not a reason to pile the next
change onto its branch. CI is a single ~10 min gate per PR and auto-merge lands it
green (see [`docs/auto-merge-and-merge-queue.md`](../../docs/auto-merge-and-merge-queue.md)),
so independent PRs are the cheap, reviewable shape — batching only widens the blast
radius of one red check.

**Park work-in-flight as a DRAFT — but it is NOT free, and the old wording here was
wrong.** With no merge queue, auto-merge lands a PR the moment its checks go green;
there is no second run to sit behind, so a branch you are still pushing to can merge out
from under you mid-stream (#567 lost five commits that way, 2026-09-22). Drafting does
remove that race.

What it also does is **drop the arming, which `ready_for_review` does not restore.** This
file used to claim the opposite — "arming survives the draft state and releases on
`ready_for_review`, so opening as a draft costs nothing" — and that is false. Measured on
#723, 2026-10-01, from the `auto-merge` workflow's own run list:

| Time | What happened | What the arm job did |
|---|---|---|
| 14:01:52 | PR opened, non-draft | `arm decision=success`, **`arm auto-merge=success`** |
| 14:05:44 | a push to the branch | run **cancelled** by the concurrency group |
| 14:05:46 | `ready_for_review` | `arm decision=success`, **`arm auto-merge=skipped`** |

The PR came back **unarmed** and stayed that way. Neither the push's run (cancelled) nor
the `ready_for_review` run restored it — which is issue #683's open bug, reached here by
following this file's own advice. Not measured: whether the draft conversion or the push
dropped the arming; only that it was dropped and not restored.

**So the draft dance costs one manual step.** Either:

- open non-draft and finish pushing before CI goes green (fine for a small change), or
- open as a draft, and after `gh pr ready` **re-arm by hand** and verify it took:
  `gh pr view <n> --json autoMergeRequest` must be non-null. Do not assume marking it
  ready re-armed it; the skip is silent and a PR that merely sits there looks the same as
  one waiting on checks.
