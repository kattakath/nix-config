# Auto-merge across the flake fleet

Every flake this operator owns merges itself once CI is green — **provided the PR
is authored by `ismailkattakath`**. Nothing here bypasses a gate: the PR still has
to satisfy the same required status checks it always did. What is removed is the
manual "Merge" click.

```
  PR opened by ismailkattakath
        |
        v
  auto-merge.yml  --(CI bot App token)-->  gh pr merge --auto --squash
        |
        v
  required checks green ON THE PR  (required-checks, Scan for secrets)
        |
        v
      merged to main  -->  push:main workflows still fire (App token, not GITHUB_TOKEN)
```

**There is no merge queue.** It was adopted 2026-08-22 and removed 2026-09-22; §3
is the record of why, and what has to be true before re-adopting one.

## The two pieces

### 1. `auto-merge.yml` — arms the PR

A `pull_request`-triggered workflow that runs `gh pr merge --auto --squash` when
`github.event.pull_request.user.login == 'ismailkattakath'` and the PR is not a
draft. Re-fires on `synchronize`, so a PR GitHub disarmed (conflict, failed check)
re-arms itself the moment the fix is pushed.

It authenticates with an **installation token from the CI bot GitHub App**, never
`GITHUB_TOKEN`. Auto-merge attributes the merge to whoever armed it, and events
produced by `GITHUB_TOKEN` do not start workflow runs — arming with it would land
every auto-merged PR on `main` silently, killing `flakehub-publish.yml` and
`build-installers.yml`. This is the single most important detail on this page.

Requires per repo: the App **installed on that repository**, plus
`vars.CI_BOT_CLIENT_ID` and `secrets.CI_BOT_APP_PRIVATE_KEY`. Both are supplied
**org-wide** on `kattakath` rather than per repo — the `ismailkattakath-ci` App
(appId 4849830, which replaced the retired org-owned `kattakath-ci` on 2026-09-06) is
installed on the org with `repository_selection: all`, and the client id is an org
variable (visibility: all). A new flake in this org therefore inherits everything
except its own `auto-merge.yml`.

`secrets.CI_BOT_APP_PRIVATE_KEY` is the App's **second** private key — deliberately a
different key from the one in agenix (`secrets/gh-app-*.age`), so either side can be
revoked without touching the other. Both authenticate as the same App, so this buys
independent rotation, not reduced permissions. Details: `secrets/secrets.nix`.

Note that **repository secrets do not survive a repo transfer** (variables and
branch protection do). Anything moved into the org needs its secrets re-set.

### 2. `protect-main` — the gate auto-merge waits on

Ruleset `18461567`: `deletion`, `non_fast_forward`, `required_linear_history`,
`pull_request` (squash-only, 0 approvals, thread resolution required) and
`required_status_checks` — two contexts, `required-checks` (`nix-ci.yml`) and
`Scan for secrets` (`gitleaks.yml`).

`strict_required_status_checks_policy` (require branches up to date) is **off**.
It was turned off when the queue landed and deliberately left off when the queue
went; see §3 for the trade that represents.

## 3. The merge queue: why it was added, and why it was removed

**Added 2026-08-22.** `strict_required_status_checks_policy` was on, and plain
auto-merge does not update a stale head branch — so with two PRs open the second
waited forever behind the first. The queue tests each entry against the projected
merged result instead, and per GitHub "does not require a pull request author to
update their pull request branch and wait for status checks to finish before
trying to merge". `strict_required_status_checks_policy` was switched **off** at
the same time, because the queue subsumed it and leaving both on re-introduces
exactly the stall the queue removes.

**Removed 2026-09-22**, for the cost, and because that justification had expired.

*The cost.* A merge queue cannot reduce a pipeline to one CI run; doubling it is
what a queue structurally **is**. GitHub: *"Once a pull request has passed all
required branch protection checks, a user with write access to the repository can
add the pull request to the queue."* The PR is gated first; the queue then re-runs
the same gate on its own `gh-readonly-queue/main/...` entry. Measured end to end on
PR #558:

| Stage | Duration |
| --- | --- |
| `nix-ci` on the PR | 10m27s |
| armed → added to queue | 21s |
| `nix-ci` on the queue entry | **7m29s** |
| merged | — |
| **open → merged** | **18m56s** |
| `nix-ci` on `push: main`, after | 8m19s |

*The expiry.* The queue was adopted to escape a strict up-to-date policy that the
queue itself then disabled. With strict off, plain auto-merge has nothing to stall
on — so by 2026-09-22 the queue's only remaining job was the 7m29s it added.

*What was given up, honestly.* Cross-PR semantic conflict detection: two PRs each
green alone, broken together. At `min_entries_to_merge: 1` and one entry per queue
run across the whole visible history, queue depth here was always **1**, so that
guarantee was never exercised. The post-merge `push: main` leg still evaluates the
merged result and surfaces a bad merge within ~8 minutes, and `required_linear_history`
+ squash makes the follow-up fix a one-commit PR.

**PRs stay independent.** The reasoning survives the queue's removal on different
grounds: CI is now a single ~10 min gate per PR, so there is no reason to batch a
session's work onto one long-lived PR. The default holds — **one PR per change,
branched off `main`** ([`.claude/rules/pr-title.md`](../.claude/rules/pr-title.md)).

### Before re-adopting a queue

Three facts cost real debugging time. They are recorded here, not deleted, because
re-adoption would walk into all three again.

**(a) Merge queue is organization-only.** `POST /repos/{owner}/{repo}/rulesets`
rejects the rule outright on a repository owned by a USER account — `422 Validation
Failed, Invalid rule 'merge_queue'` — with no hint that ownership is the cause.
This is why all seven satellite flakes were moved off the `ismailkattakath` user
account into the `kattakath` org. A GitHub **Free** org is enough, for public repos.

**(b) Every workflow producing a REQUIRED context needs a `merge_group:` trigger.**
A queue entry is built on its own `gh-readonly-queue/main/...` ref, which emits
neither `pull_request` nor `push`. A required check whose workflow lacks the
trigger never reports on the entry, and the merge times out
(`check_response_timeout_minutes`). In this repo that meant `nix-ci.yml` and
`gitleaks.yml` — both triggers were removed with the rule.

**(c) The queue app must satisfy every ruleset rule ON ITS OWN.** The queue does
not merge as *you*: it hands the merge to the **GitHub Merge Queue** app, which
re-evaluates the ruleset **as itself**, and it is not in `bypass_actors`. A
Repository-admin bypass does not transfer. A rule it cannot satisfy is GitHub's
documented removal reason "branch protection failure that could not automatically
be resolved", and it fires **instantly**, looking nothing like the (b) timeout:

| | `merge_group:` missing (b) | rule the queue can't satisfy (c) |
| --- | --- | --- |
| Time in queue | `check_response_timeout_minutes` (60 min) | ~15 s |
| `gh-readonly-queue/main/...` ref | created | **never created** |
| `merge_group` Actions runs | none — that *is* the bug | **none** |
| Rule-suite evaluation | present | **none** |

With no ref, no runs and no rule-suite entry there is nothing to read: the queue page
looks **empty** (the entry is already gone) while the PR box still shows a stale amber
"queued". The **"Merge without waiting for requirements (bypass rules)"** checkbox does
not help — it bypasses the gate on the PR, then still hands off to the queue app that
lacks the bypass.

Concretely, 2026-08-29: `protect-main` carried
`require_extra_approval_for_unattributed_changes: true`, inert while
`required_approving_review_count` is `0` and no queue existed. The first Dependabot
PR to reach the queue (#316) was ejected after **14 s** — the rule raises an
agent-authored PR to one required approval, it had zero, and the queue cannot
self-approve. Fixed by setting the flag `false`. It is still `false` today.

Audit any repo before adding the rule back:

```bash
gh api repos/kattakath/<repo>/rulesets/<id> --jq '{bypass: .bypass_actors, pr: (.rules[] | select(.type=="pull_request") | .parameters)}'
```

## Cost today

**One blocking CI run per PR.** `build-installers.yml` remains deliberately **not**
a required check — its non-cancellable runs have no business gating a merge.

The post-merge `push: main` run is **kept**: with no queue entry to validate the
projected merge, it is the only thing that evaluates what actually landed, and it
warms Cachix under `main`'s own rev (the four tree-dependent checks take `self`, so
their store paths differ per rev) for the operator's local `nix flake check`.

## The fleet

| Repo | Required context(s) | Merge mechanism |
| --- | --- | --- |
| `kattakath/nix-config` | `required-checks`, `Scan for secrets` | auto-merge, no queue |

This table had a second row until 2026-09-12: `ircc-whatsapp-bot`. It was never a
`nix-config` input — it was here because membership is "has its own CI and its own
merge-when-green rule", not "is consumed by the fleet flake". It came out when
nix-personal unwired the bot; the repo still exists and still has its own pipeline, it
is simply no longer the fleet's concern.

**ADR-002 took this table from ten repos to one, and that is finished.**
([`monoflake-capsule-adr.md`](monoflake-capsule-adr.md).) Each of the seven satellite
flakes was absorbed into `nix-config` as a `modules/features/<name>/` capsule and its repo
archived, which retires one ruleset, one merge queue and one `ci.yml` apiece:

| Left at | Repo | Now |
| --- | --- | --- |
| wave 3 | `kattakath/nix-cloudflared-connector` | `modules/features/cloudflared-connector/` |
| wave 4 | `kattakath/nix-firmware-secrets` | `modules/features/firmware-secrets/` |
| wave 4 | `kattakath/nix-keychain-secrets` | `modules/features/keychain-secrets/` |
| wave 4 | `kattakath/nix-vast-provision` | `modules/features/vast-provision/` |
| wave 5 | `kattakath/nix-tart-vms` | `modules/features/tart-vms/` |
| wave 5 | `kattakath/nix-media-cli` | `modules/features/media-cli/` |
| wave 6 | `kattakath/nix-local-rag` | `modules/features/local-rag/` |

**The satellite count is 0**, and their ~25 absorbed checks now ride `nix-config`'s single
`required-checks` aggregate. The archiving itself is an operator action on GitHub, not
something any workflow in this repo performs.

**Then three became two, and two became one.** `kattakath/nix-mcp-gateway` was
**archived on 2026-09-12**, retiring its ruleset, its merge queue and its `ci.yml`
exactly as the seven above did — but for the **opposite reason**. It was never a
satellite and never became a capsule: it was an unadopted extraction candidate, a thin
generic `local.mcpGateway` broker module the fleet never consumed, because
`modules/shared/mcp.nix` is and always was the fleet's own wired deployment. Nothing came
in-tree when it left, because nothing was ever taken in. `kattakath/nix-inngest` was
archived the same day for the same reason; it never appeared in this table, having had no
merge queue of its own. Archived, **not deleted** (ADR-002 §7.8), so both remain public
and readable.

The private `ismailkattakath/nix-personal` (GitLab) is **out of scope**: it has no
`.gitlab-ci.yml` at all, so there is no pipeline for a merge-when-green rule to
wait on. GitLab's equivalent is "merge when pipeline succeeds" plus
`only_allow_merge_if_pipeline_succeeds` — both meaningless until that repo has CI.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| PR never arms; `arm auto-merge` job fails at the token step | CI bot App not installed on that repo, or the secret/var missing | Install the App on the repo; set `CI_BOT_APP_PRIVATE_KEY` + `CI_BOT_CLIENT_ID` |
| PR armed, checks green, never merges | Unresolved review thread (`required_review_thread_resolution`) | Resolve the thread |
| PR armed but never merges, no checks running | Real merge conflict — GitHub disarms it | Resolve and push; `synchronize` re-arms automatically |
| Merged, but nothing published to FlakeHub | Something armed the PR with `GITHUB_TOKEN` | Restore the App token in `auto-merge.yml` |
| Someone else's PR auto-merged | The author guard was widened | The guard is a literal login; keep it that way |
| PR merges against a `main` that moved under it | Expected — `strict_required_status_checks_policy` is off by choice (§3) | The `push: main` leg catches it; fix forward |

## Turning it off

Delete `.github/workflows/auto-merge.yml` — PRs stop arming, everything else
unchanged. To go the other way and re-add a queue, read §3 "Before re-adopting a
queue" first: add the `merge_queue` rule to the ruleset, restore `merge_group:` to
`nix-ci.yml` and `gitleaks.yml`, and accept the second CI run.
