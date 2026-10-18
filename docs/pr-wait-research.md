# PR-wait research — findings and a deferred lever backlog (2026-10-18)

**Status: RESEARCH ONLY — nothing here is implemented.** The operator asked for it documented
to act on later. Every lever below is a candidate, ranked on evidence; none is decided.

Scope: `kattakath/nix-config` only. Method: a prompt-engineered brief, four parallel read-only
agents (history census, CI critical path, industry research, session-transcript waits), then an
adversarial verifier that re-derived the top claims with differently shaped instruments.

## Verdict

- **Measured keyboard waiting is small: 6.4–8.4 min per calendar day** (October, session
  transcripts covering 168/176 = 95% of operator PRs). **53% came from ONE chained session**
  on 2026-10-02.
- **That is far below "a lot of time"** — so either the cost is waiting OUTSIDE Claude
  sessions (GitHub tab, phone; **unmeasured**), or it is the *interruption*, not the minutes
  (Parnin & Rugaber: only 10% of programmers resumed editing within 1 min).
- **Clock time is CI.** The final CI run is **92%** of open→merge at p50 (6.78 of 7.4 min;
  census n=248, 2026-09-23→10-18). The `build (aarch64-darwin)` leg is the long pole in
  **253/253** PRs.
- **Root cause found:** `checks.<sys>.deploy-schema` (`modules/parts/deploy.nix`,
  `deploySchemaSubject`) interpolates the real nixpi toplevel and then
  `unsafeDiscardStringContext`s it. That drops the BUILD edge but keeps the EVAL edge, so eval
  instantiates 12,071 derivations including `linux-rpi` and `raspberrypi-firmware`, and the
  darwin leg cold-fetches their sources: **≤67 s per run** (upper bound, n=5 logs). The other
  51 darwin checks reference neither (traced with `-vvv`).

## Two losses — never sum them

The agent polls *during* the CI run, so the two overlap in time.

| Loss | What it measures | Size |
|---|---|---|
| Keyboard | agent busy-polls CI inside its turn | 6.4–8.4 min/day |
| Clock | open → merge, mostly the final CI run | p50 7.4 min/PR, ~9.7 PRs/day |

Denominator: **calendar days** (~9.7 PRs/day). Per-active-day figures (14.9–29.3) overstate it;
3 burst days held 85% of October's PRs.

## Darwin leg, where the time goes (p50)

| Step | darwin | linux |
|---|---|---|
| Determinate Nix install | 64–66 s | 6 s |
| Input unpack | 34 s | 10 s |
| Eval + plan (incl. source-tree fetch) | 127 s | 46 s |
| Build + Cachix push | 23 s | 7 s |

Builds are cheap. In 38/40 runs darwin rebuilt only checks linux also builds.

## Lever backlog (ranked)

| # | Lever | Saves | Effort | Evidence |
|---|---|---|---|---|
| 1 | Agents never poll CI in-turn: rely on the armed auto-merge; background `gh pr checks --watch` / Monitor; notify only on RED or "merged, needs activate" | keyboard 6–8 → ~0 min/day | S | transcripts; only 1.5% of 32,201 Bash calls ran in background |
| 2 | `deploy-schema` validates a context-free placeholder store path, not the real toplevel | ≤1.1 min/PR | S | eval trace; prove with `scripts/drv-snapshot.sh --compare` |
| 3 | #2 + run `legs` in parallel as a verifier (~0.8) + eval `darwinConfigurations.macos` on the linux leg (~0.4) + PR darwin legs build only darwin-only checks (~0.4) | ~2.6 min/PR total (6.1 → 3.5) | S–M | job timings n=40, re-checked n=8 |
| 4 | **POLICY:** darwin leg advisory on owner PRs | ~3.5 min/PR — **subsumes #3, not additive** | S | overrides CLAUDE.md § Testing two-system rule; 3/983 PR runs failed darwin-only and would surface post-merge |
| 5 | Direct push for docs/`.claude`-only changes (~21% of PRs) | ~7.5 min for those | S | trunkbaseddevelopment.com "committing straight to the trunk"; Fowler "Ship". **Risk:** no local gitleaks hook exists, so a secret is public before the scan |
| 6 | Dependent chains: one PR, or branch N+1 off N | ~7 min per serial link | S | trunk-based precedent; the 10-02 chained session |

- **Quick wins (≤1 h, reversible):** #1, #2, and diagnosing the 14 unarmed PRs below.
  **Diagnosis DONE (`pr-wait/auto-merge-arming`):** not a defect, no code change — see
  § Not waiting.
- **Merge-queue history check:** none of #1–#6 re-runs the gate on a second ref, so none
  repeats the reason in [`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md) §3.

## Rejected — and why each lost

| Option | Why it lost |
|---|---|
| Merge queue (GitHub, Mergify, Trunk, Bors, Aviator) | Re-runs the gate on its own ref (the 2026-09-22 removal reason); one author never contends it → 0 min |
| Graphite stacks | Vendor effect sizes come from review-bound teams (0 approvals here); its queue doubles CI |
| Swap to nix-quick-install-action | ~0.9 min, but CI would run upstream Nix while the fleet runs Determinate |
| Path filtering | Only 7% of PRs are docs-only → ~0.2 min average |
| `concurrency.queue: max` | Real (it explains 17/128 cancelled push:main runs), but saves 0 min and is invalid alongside `cancel-in-progress: true` |
| magic-nix-cache / Garnix / FlakeHub Cache / xlarge macOS | Free tier ended 2025-02-01 / shut down 2026-07-15 / paid second cache / paid plan |
| nix-fast-build, cache-nix-action | Already measured slower here, or warned slower by its own README |

## Not waiting — do not count as lost time

- **27 multi-run PRs** (37.5% of summed wall-clock): the agent was still pushing fixes.
- **Draft-parked time** (33.7%): deliberate parking.
- **14 PRs "never armed for auto-merge"** — **DIAGNOSED (branch `pr-wait/auto-merge-arming`):
  not a defect, and not a separate loss.** Every one was armed in effect; the lag is the
  draft-parked time in the bullet above, counted a second time. **No workflow change.**

### The 14 "unarmed" PRs — diagnosis

**Verdict:** arming works. Of **258** operator PRs since 2026-09-23 (merged or closed), 244
carry an arm event, 13 were merged directly by the arm step, and 1 was hand-merged. Zero
failed to arm. Lever #1 is unblocked.

**Why no arm event exists.** `gh pr merge --auto` does not arm a PR that is already
mergeable. gh's `pkg/cmd/pr/merge/merge.go` sets `autoMerge` only when
`!isImmediatelyMergeable(pr.MergeStateStatus)`, and `isImmediatelyMergeable` is true for
`CLEAN`, `HAS_HOOKS` and `UNSTABLE` (read at gh 2.101.0). So on a green PR the arm step
**merges on the spot**, and the timeline gets a `merged` event, never `auto_squash_enabled`.
gh's `infof` prints nothing off a TTY, so the runner log is **silent** either way. That is
why this looked like a failure.

**The shared shape (13 of 14):** opened as a draft → arm job `skipped` (correct) →
`required-checks` green **while still a draft** → `ready_for_review` → arm job `success` →
merged by `ismailkattakath-ci[bot]` **10–14 s later**. #697 is the one exception: it was
hand-merged 7 s after the ready transition, 1 s after the arm job started. It was the
deliberate human-merge sample in
[`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md)'s closing-keyword table.

| PR | green (UTC) | ready | green→merged min | ready→merged | merged by |
|---|---|---|---|---|---|
| #579 | 09-23 01:16 | 09-23 01:29 | 13.3 | 13 s | `ismailkattakath-ci` |
| #580 | 09-23 01:17 | 09-23 01:29 | 13.1 | 13 s | `ismailkattakath-ci` |
| #581 | 09-23 01:28 | 09-23 01:31 | 2.4 | 11 s | `ismailkattakath-ci` |
| #583 | 09-23 01:32 | 09-23 01:32 | 0.1 | 11 s | `ismailkattakath-ci` |
| #596 | 09-23 07:16 | 09-23 07:33 | 16.8 | 11 s | `ismailkattakath-ci` |
| #624 | 09-23 15:39 | 09-23 16:03 | 23.6 | 12 s | `ismailkattakath-ci` |
| #625 | 09-23 20:21 | 09-24 05:16 | **535.7** | 10 s | `ismailkattakath-ci` |
| #670 | 09-30 20:26 | 09-30 21:10 | 44.1 | 14 s | `ismailkattakath-ci` |
| #673 | 09-30 22:02 | 09-30 22:10 | 8.2 | 12 s | `ismailkattakath-ci` |
| #675 | 09-30 21:51 | 09-30 21:52 | 1.9 | 11 s | `ismailkattakath-ci` |
| #676 | 09-30 20:49 | 09-30 21:53 | 64.9 | 11 s | `ismailkattakath-ci` |
| #697 | 10-01 03:01 | 10-01 03:49 | 48.0 | 7 s | `ismailkattakath` (hand) |
| #699 | 10-01 04:05 | 10-01 04:42 | 37.2 | 11 s | `ismailkattakath-ci` |
| #855 | 10-17 22:16 | 10-17 22:23 | 7.2 | 10 s | `ismailkattakath-ci` |

**Sum: 816 min green→merged, of which 814 min is green→ready** — the PR sat green as a
draft. Ready→merged totals ~2.6 min. So the minutes belong to draft parking, not to arming.
If the agent marked a green draft ready sooner, that lag would vanish; that is lever #1's
territory (notify on green), not a workflow defect.

**The other 5 PRs without an arm event are Dependabot's**, armed by `arm-dependabot.yml`'s
sweep, not by `auto-merge.yml`:

| PR | Cause |
|---|---|
| #633 | Predates `arm-dependabot.yml` (landed #701, 2026-10-01); it is that file's motivating case |
| #708 | The first `workflow_dispatch` sweep hit a green PR → direct merge (same gh path) |
| #820, #822 | A scheduled sweep hit a green PR → direct merge |
| #736 | Hand-merged between sweeps (05:34 and 12:31) |

**Data on #683:** #855 (2026-10-17) is the first `ready_for_review` sample since #750 turned
`cancel-in-progress` off. It got **exactly one** non-skipped arm run, which merged it. One
sample; the issue is not re-characterised here.

**Instrument** (scratchpad, not retained): one GraphQL `pullRequests(states:[MERGED,CLOSED])`
query over `timelineItems` (`AUTO_MERGE_ENABLED_EVENT`, `AUTO_SQUASH_ENABLED_EVENT`,
`AUTO_MERGE_DISABLED_EVENT`, `CONVERT_TO_DRAFT_EVENT`, `READY_FOR_REVIEW_EVENT`,
`MERGED_EVENT`) with `gh api graphql --paginate` (804 PRs, 267 since 09-23). Then
`gh api --paginate …/workflows/auto-merge.yml/runs` (342 runs), per-run `/jobs`, and the
head SHA's `required-checks` check run. A **workflow-run** conclusion of `success` does not
mean the arm job ran: since #713 the `arm decision` job succeeds on every run. Read the
**job** conclusion.

## Derived vs assumed

- **Derived:** the CI decomposition (census), the deploy-schema root cause (trace), the
  busy-wait minutes (transcripts).
- **Assumed:** busy-wait minutes equal operator-blocked minutes — no presence signal exists.
- **Weakest assumption:** that in-session waits are the whole cost. Settle it with Screen Time /
  `knowledgeC` or browser history for GitHub PR pages.

## How to tell a lever worked

- **#2/#3:** PR nix-ci p50 baseline **6.78 min** (p90 7.93). Spread ≈1 min → SE(median) ≈0.23
  min at n=30 PRs (~3 days), so a 1-min drop is ~4 SE. Revert if a darwin-only failure ever
  reaches `main`.
- **#1:** re-count in-turn wait gaps in the session transcripts weekly; target < 1 min/day.
- **#5:** time one local `nix flake check --all-systems --no-build` + `nix flake check`; adopt
  only if it beats the PR p50.
- The measurement scripts lived in a session scratchpad and are **gone**; re-measuring means
  rebuilding them (`gh api --paginate` over pulls, actions runs and jobs).

## Incidental doc rot found (not fixed)

- `nix-ci.yml`'s `legs` comment says it is not on the critical path — its `needs:` edge puts
  ~45 s in front of darwin in 40/40 runs.
- `docs/map/ci.md` has drifted from the workflow (`legs` runner, nix-fast-build).
- `nix-ci.yml`'s header credits Determinate's parallel eval beyond its documented scope
  (flake check/show, eval --json, search — not `nix build <attrs>`).
- `arm-dependabot.yml`'s cron comment says "Every 6 h bounds the arming latency". **Measured
  false:** 55 scheduled runs against 68 nominal `17 */6` slots (2026-10-01→10-18, so **13
  dropped**). Gap between runs: p50 7.1 h, p90 9.7 h, **max 13.5 h**. #822 sat green for
  5.3 h waiting for a sweep. Out of the auto-merge lane; not fixed.
