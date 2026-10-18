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

Two refinements, both from [`docs/pr-wait-research.md`](../../docs/pr-wait-research.md):

- **Docs / `.claude`-only changes need no PR at all.** They may go straight to `main` after
  the local gate. The path allowlist and the gate live in
  [`landing-changes.md`](landing-changes.md) § 2, not here.
- **A DEPENDENT change never waits for its parent to merge** (lever #6, ~7 min per serial
  link). When N+1 needs unmerged N:
  - **One logical change?** Fold N+1 into N's PR. That is not batching; it is one change.
  - **Two changes?** Branch N+1 off N's branch and open it as a DRAFT:
    `gh pr create --draft --base <N-branch>`. **The draft is mandatory.** `auto-merge.yml`
    arms every non-draft operator PR whatever its base, and `protect-main` guards only the
    default branch. So an armed N+1 could land in N's branch with no required checks.
  - When N squash-merges, GitHub deletes its branch (`delete_branch_on_merge: true`, read
    2026-10-18) and retargets N+1 to `main`. N+1 still carries N's pre-squash commits, so
    run `git rebase --onto origin/main <N-head> && git push --force-with-lease`, where
    `<N-head>` is N's last pre-squash commit (your local N branch still points at it). The lease
    form is allowed; `claude-guardrails.nix` denies only bare `--force`/`-f`. Then run
    `gh pr ready`, which arms it.
  - "Off `main`" above means off `main` **or off the unmerged PR it depends on**. Never off
    an unrelated open PR — that is the batching this section rejects.

**Park work-in-flight as a DRAFT — it needs no manual step.** With no merge queue,
auto-merge lands a PR the moment its checks go green; there is no second run to sit behind,
so a branch you are still pushing to can merge out from under you mid-stream (#567 lost five
commits that way, 2026-09-22). Drafting removes that race, and costs nothing to undo:
converting to a draft **does** drop the arming — GitHub fires `auto_merge_disabled` in the
same second as `convert_to_draft`, on **4 of 4** conversions of an already-armed PR — and
**`ready_for_review` re-arms it**, as a fresh `auto_squash_enabled` ~10-12 s later.

**CORRECTED 2026-10-02 — and this section has now been wrong in BOTH directions.** It first
claimed arming *survives* the draft state; the 2026-10-01 rewrite claimed `ready_for_review`
does **not** restore it and told you to re-arm by hand. The second claim is also false, and
the #723 table it rested on had its two rows **swapped**. Matching each run to its event by
`head_sha` — the PR head was `848a6c0e` until the push created `78f956b3` — #723 reads:

| Time | Event | Run head | arm job | Why |
|---|---|---|---|---|
| 14:01:52 | `opened`, non-draft | `848a6c0e` | **success** | armed — `auto_squash_enabled` 14:02:02 |
| 14:04:50 | `convert_to_draft` | no run (no trigger) | — | **`auto_merge_disabled` the same second. THIS dropped it** |
| 14:05:38 | push → `78f956b3` | — | — | fired BEFORE the ready transition |
| 14:05:40 | `ready_for_review` | `848a6c0e` | **cancelled** | killed by `cancel-in-progress`, then `true` |
| 14:05:46 | `synchronize` | `78f956b3` | **skipped** | payload `draft=true` — CORRECT, the push preceded the toggle |

The old table read the cancelled run as the push's and the skipped run as the ready
transition's. Both are the other way round: the cancelled run carries the **pre-push** head,
so it is the ready transition, and the skip is a by-design draft skip, not the defect. What
left #723 unarmed is the **cancellation** — removed by #750 (`cancel-in-progress: false`,
2026-10-02), not by anything in this file.

Both of the old claims are refuted at job level, not inferred:

| What the old text said | Measured |
|---|---|
| a push drops the arming | **14/14** `synchronize` runs on non-draft operator PRs armed; #737 was force-pushed 3x while armed and `enabledAt` never moved |
| `ready_for_review` does not restore it | **3 of the 4** armed-PR conversions re-armed on the ready transition (#559, #737, #757); only #723 did not, by the cancellation above. Of 5 `ready_for_review` runs with a recorded payload, 4 armed and 1 was cancelled — **zero skips** |

**#683 is still open, so glance — do not re-arm.** No draft→ready transition has happened
since the cancellation was turned off, so its acceptance criterion (exactly one non-skipped
arm run per transition) has no post-fix sample.

**The one check worth keeping** — read `autoMergeRequest` only after the arm run concludes
(#747) — now lives in [`landing-changes.md`](landing-changes.md) § 1, which also says HOW to
wait: in the BACKGROUND, never by polling inside a turn. "Glance" above means one look from
that background watch, not a foreground loop.
