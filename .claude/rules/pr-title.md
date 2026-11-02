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
change onto its branch. CI is one heavy run per PR, in the merge queue, and auto-merge lands it
green (see [`docs/auto-merge-and-merge-queue.md`](../../docs/auto-merge-and-merge-queue.md)),
so independent PRs are the cheap, reviewable shape — batching only widens the blast
radius of one red check.

Two refinements, both from [`docs/pr-wait-research.md`](../../docs/pr-wait-research.md):

- **Docs / `.claude`-only changes need no PR at all.** They may go straight to `main` after
  the local gate. The path allowlist and the gate live in
  [`landing-changes.md`](landing-changes.md) § 2, not here.
- **A DEPENDENT change never waits for its parent to merge** (lever #6, ~7 min per serial
  link). When N+1 needs unmerged N:
  - **One logical change?** Fold N+1 into N's PR. That is not batching; it is one change.
  - **Two changes?** Branch N+1 off N's branch and open it as a DRAFT:
    `gh pr create --draft --base <N-branch>`. **The draft is mandatory.** `auto-merge.yml`
    arms every non-draft operator PR whatever its base, and the `main` ruleset guards only the
    default branch. So an armed N+1 could land in N's branch with no required checks.
  - When N squash-merges, GitHub deletes its branch (`delete_branch_on_merge: true`, read
    2026-10-18) and retargets N+1 to `main`. N+1 still carries N's pre-squash commits, so
    run `git rebase --onto origin/main <N-head> && git push --force-with-lease`, where
    `<N-head>` is N's last pre-squash commit (your local N branch still points at it). The lease
    form is allowed; `claude-guardrails.nix` denies only bare `--force`/`-f`. Then run
    `gh pr ready`, which arms it.
  - "Off `main`" above means off `main` **or off the unmerged PR it depends on**. Never off
    an unrelated open PR — that is the batching this section rejects.

**Park work-in-flight as a DRAFT — it needs no manual step.** An armed PR is queued the
moment `gate` goes green on it, which takes SECONDS now that the heavy suite runs in the
queue, so a branch you are still pushing to can merge out from under you mid-stream (#567
lost five commits that way, 2026-09-22, when no queue existed). Drafting removes that race, and costs nothing to undo:
converting to a draft **does** drop the arming — GitHub fires `auto_merge_disabled` in the
same second as `convert_to_draft`, on **4 of 4** conversions of an already-armed PR — and
**`ready_for_review` re-arms it**, as a fresh `auto_squash_enabled` ~10-12 s later.

**Two behaviours, both measured at job level:** a push to an armed PR never drops the arming
(14/14), and `ready_for_review` re-arms a drafted one. This section was wrong in BOTH
directions before 2026-10-02; the #723 event table and the refutation of both old claims live
in [`pr-wait-research.md`](../../docs/pr-wait-research.md) § The 14 "unarmed" PRs.

**#683's root cause is still unpinned (its 2026-11-01 close was a keyword side effect), so glance — do not re-arm.** Since #750 turned the cancellation off,
**6 of 6** draft→ready transitions met its acceptance criterion (exactly one non-skipped arm
run per transition; census in [`pr-wait-research.md`](../../docs/pr-wait-research.md) § The
14 "unarmed" PRs). A green PR shows a `merged` event and **no** `auto_squash_enabled`: `gh pr
merge --auto` merges an already-green PR on the spot instead of arming it — not a skip.

**The one check worth keeping** — read `autoMergeRequest` only after the arm run concludes
(#747) — now lives in [`landing-changes.md`](landing-changes.md) § 1, which also says HOW to
wait: in the BACKGROUND, never by polling inside a turn. "Glance" above means one look from
that background watch, not a foreground loop.
