# PR-wait research — findings and a deferred lever backlog (2026-10-18)

**Status: the operator authorised every lever on 2026-10-18; all six are IMPLEMENTED.** Per-lever
status sits under the backlog table. The research text below is kept as measured.

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

### Implementation status

| # | Status | What landed, and its evidence |
|---|---|---|
| 1 | **IMPLEMENTED** | [`.claude/rules/landing-changes.md`](../.claude/rules/landing-changes.md) § 1 (this repo), plus `claude/CLAUDE.md` § CI waits (every repo, because the cost comes from the harness, not the repo). `pr-title.md`'s `autoMergeRequest` race note moved there, so it has ONE home |
| 2 | **IMPLEMENTED** | `deploySchemaSubject` feeds a context-free placeholder path. Darwin eval of the check: **13,871 → 1,827** derivations instantiated, `linux-rpi`/`raspberrypi-firmware` **5 → 0**. `deploy.nodes.nixpi` keeps the real toplevel (same `.drv`); a bad `magicRollback` type still fails the check |
| 3 | **IMPLEMENTED** | `legs` is a parallel verifier (no `needs:` edge); the linux leg evaluates every host incl. macos (pure eval + IFD off, measured on the Mac; a real linux evaluator is unmeasured until the first CI run); the darwin PR leg builds only its **29 of 52** darwin-only checks (after renaming the two `determinate-daemon` host contracts apart), push:main builds all |
| 4 | **IMPLEMENTED** | Darwin is ADVISORY on PRs whose author id is the operator's: the required darwin job skips, an advisory twin runs the full leg, `required-checks` does not need it. `author_association == 'OWNER'` never matches (org-owned repo, operator reads `MEMBER`) |
| 5 | **IMPLEMENTED** | `landing-changes.md` § 2: the path allowlist plus a local gate that mirrors the three required checks. **The stated risk is closed:** `checks.<sys>.pre-commit` now runs gitleaks over the tree (`modules/parts/devshell.nix`, measured RED on a planted canary token), and the gate adds `gitleaks git` over the unpushed range. It is **not** a commit hook; the devShell installs none, by design. **The adoption test above passed** (2026-10-18, warm store, eval cache OFF): `--all-systems --no-build` 6 s, `nix flake check` 9 s with 7 checks rebuilt, the range scan 3 s. That is far under the 6.78 min PR p50, though a cold store is unmeasured |
| 6 | **IMPLEMENTED** | `pr-title.md` § One PR per change: fold N+1 into N, or branch it off N as a **DRAFT** (`auto-merge.yml` arms any non-draft PR whatever its base) |

Not measured: the CI minutes saved. Measure it with the p50 rule under § How to tell a lever
worked. Mechanics: [`map/ci.md`](map/ci.md).

- **Quick wins (≤1 h, reversible):** #1, #2, and diagnosing the 14 unarmed PRs below.
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
- **14 PRs never armed for auto-merge** explain most of the green→merged lag. **Cause
  undiagnosed** — and lever #1 depends on arming working.

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

## Incidental doc rot found — FIXED on `pr-wait/ci-critical-path`

- `nix-ci.yml`'s `legs` comment said it was not on the critical path — its `needs:` edge put
  ~45 s in front of darwin in 40/40 runs. **Fixed:** the edge is gone (lever #3), and the
  comment now records the measurement.
- `docs/map/ci.md` had drifted from the workflow (`legs` runner, nix-fast-build). **Fixed:**
  the section was rewritten against the new jobs, and the check counts were re-measured.
- `nix-ci.yml`'s header credited Determinate's parallel eval beyond its documented scope
  (flake check/show, eval --json, search — not `nix build <attrs>`). **Fixed** in the leg's
  install-step comment, now in `nix-ci-impl.yml`.
- `CONTRIBUTING.md` still described a 2-leg matrix building with nix-fast-build and every
  leg evaluating every host. **Fixed:** it now points at `docs/map/ci.md` and states the
  per-author required/advisory split.
