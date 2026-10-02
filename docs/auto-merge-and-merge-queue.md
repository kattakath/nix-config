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
draft. Triggers are `opened`, `reopened`, `ready_for_review` and `synchronize`, and
arming is **idempotent** — so a PR GitHub disarmed re-arms itself: on `synchronize` the
moment a conflict or failed check is fixed and pushed, and on `ready_for_review` after a
draft conversion (which disarms — see §3). No arm run is cancelled; `cancel-in-progress`
is `false`.

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

**That is ONE PR, not the norm — do not read 10m27s as typical.** Measured 2026-10-01 over the
last 37 successful `pull_request` runs of `nix-ci.yml`: **median 7.1 min**, p90 8.2, max 10.2, min
5.2. #558's 10m27s sat at the top of that range, and its 18m56s open→merged reflects the queue
leg that no longer exists.
| `nix-ci` on `push: main`, after | 8m19s |

*The expiry.* The queue was adopted to escape a strict up-to-date policy that the
queue itself then disabled. With strict off, plain auto-merge has nothing to stall
on — so by 2026-09-22 the queue's only remaining job was the 7m29s it added.

*What was given up, second, and not anticipated.* The queue's extra run was also an
accidental **grace period**: ~7m29s between a PR going green and actually merging. A
branch still being pushed to was implicitly relying on that window. Removing it
**exposed** an operator error rather than causing one — auto-merge did exactly what it
is built to do — but masking an error is not the same as preventing it, and the mask is
gone. Measured the same day, PR #567: auto-merge fired the moment CI went green while
commits were still being pushed, squashed two phases and left **five later commits
behind**.

**Mitigation: park work-in-flight as a draft.** Still the right mitigation — but
**CORRECTED 2026-10-02**, because the mechanism this line asserted was backwards and its
own evidence refutes it. It read: *"Arming survives the draft state and releases on
`ready_for_review` — verified on #559 (armed 15:30:33 while draft …)"*. #559's timeline
says otherwise:

| #559 | What GitHub did |
|---|---|
| 15:30:18 | PR created **non-draft** — so 15:30:33's `auto_merge_enabled` is an ordinary open-arm, not an arm "while draft" |
| 15:48:56 | `convert_to_draft` **and `auto_merge_disabled`, the same second** — the arming was DROPPED |
| 16:11:31 → 16:11:43 | `ready_for_review`, then a **fresh** `auto_squash_enabled` 12 s later — RE-armed |
| 16:19:54 | merged |

So conversion **drops** the arming and `ready_for_review` **re-establishes** it. What was
read as survival was a re-arm. The net effect is the same and drafting remains the
mitigation, but the distinction is load-bearing: a transition that must re-arm can be
**lost**, and one that survives cannot.

Measured across all four draft conversions in the visible history: `auto_merge_disabled`
lands in the same second as `convert_to_draft` every time, and three of the four re-armed
within ~12 s of the ready transition (#559, #737, #757). The fourth, #723, did not — its
ready-transition arm run was **cancelled** by `cancel-in-progress`, since turned off
(#750, `auto-merge.yml`'s `concurrency` block carries the argument). That is the live tail
of #683, and [`.claude/rules/pr-title.md`](../.claude/rules/pr-title.md) carries the
operator-facing version.

*What was given up, honestly.* Cross-PR semantic conflict detection: two PRs each
green alone, broken together.

**The reason this costs little is NOT that queue depth was always 1** — that was the
argument first written here and it does not hold. Depth measures *batching*; a queue at
depth 1 still rebuilds its entry against main's current tip, so the protection operates
perfectly well at depth 1.

The real reason is stronger: **PR CI already tests the merged result.** The checkout step
logs `Merge <sha> into <base>`, so a PR is validated as merged, not as its branch. The
queue's only marginal value is therefore the ~7-minute window in which `main` can move
between that merge-test and the actual merge — and across the visible history, with a
24-27% stale-base share, that window produced **zero** conflicts. The post-merge `push: main` leg still evaluates the
merged result and surfaces a bad merge, and `required_linear_history` + squash makes the
follow-up fix a one-commit PR.

**Two caveats on that safety net, measured rather than assumed.** It used to be cancelled
on roughly a third of merges — 29 cancelled / 70 success / 1 failure over the last 100
`push: main` runs — because `cancel-in-progress` was a flat `true`, so each merge killed
the previous merge's run. #698 scoped it to non-`main` refs, so from that commit the leg
actually completes per merge. And the "~8 minutes" is per **burst**, not per merge: when
several merges land inside one run's window, one completed run covers the lot, so
per-merge attribution was what the cancellation destroyed — which is why #698 was a
measurability fix rather than a coverage one.

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

**This footgun is now SATISFIED, not outstanding.** Verified 2026-10-01: `kattakath` is an
`Organization` and `kattakath/nix-config` is public, so merge queues are available here.
Re-adoption is a **live option**, not blocked — the 422 fact applies to user-owned repos,
which this no longer is. Only (b) and (c) remain as real work.

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

**One blocking CI run per PR.** Measured on the PR that removed the queue (#560,
2026-09-22): **9m43s open -> merged**, against 18m56s for PR #558 the same morning
under the queue.

`build-installers.yml` remains deliberately **not** a required check — its
non-cancellable runs have no business gating a merge.

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
| wave 4 | `kattakath/nix-vast-provision` | absorbed, then **removed wholesale 2026-09-12** — no capsule today |
| wave 5 | `kattakath/nix-tart-vms` | `modules/features/tart-vms/` |
| wave 5 | `kattakath/nix-media-cli` | `modules/features/media-cli/` |
| wave 6 | `kattakath/nix-local-rag` | `modules/features/local-rag/` |

**The satellite count is 0**, and their ~25 absorbed checks now ride `nix-config`'s single
`required-checks` aggregate. Six of the seven **absorbed** capsules survive; the `vast-provision`
row stays because this table records a **retired ruleset**, and that stays retired whether or
not the capsule outlived the absorption (ADR-002 §9; `modules/features/` holds seven capsules
today, six absorbed satellites plus the in-tree-born `cloud-cli`). The archiving itself is an
operator action on GitHub, not something any workflow in this repo performs.

**Then three became two, and two became one.** `kattakath/nix-mcp-gateway` was
**archived on 2026-09-12**, retiring its ruleset, its merge queue and its `ci.yml`
exactly as the seven above did — but for the **opposite reason**. It was never a
satellite and never became a capsule: it was an unadopted extraction candidate, a thin
generic `local.mcpGateway` broker module the fleet never consumed, because
`modules/shared/mcp.nix` was and always had been the fleet's own wired deployment. (**Both are
gone now** — that module and the whole MCP gateway were deleted 2026-10-02.) Nothing came
in-tree when it left, because nothing was ever taken in. `kattakath/nix-inngest` was
archived the same day for the same reason; it never appeared in this table, having had no
merge queue of its own. Archived, **not deleted** (ADR-002 §7.8), so both remain public
and readable.

The private `ismailkattakath/nix-personal` (GitLab) was **retired 2026-09-15** and is no
longer a question this page has to answer. It never qualified for the table while it lived:
it carried no `.gitlab-ci.yml` at all, so there was no pipeline for a merge-when-green rule
to wait on.

## Closing keywords and the App token — the whole investigation, in one table

**Keep this table.** It took hours to isolate and the symptom is indistinguishable from "someone forgot
the keyword", so without it this gets re-diagnosed from scratch.

**Symptom:** a merged PR carrying a GitHub-parsed `Closes #N` did not close `#N`. Every completed issue
had to be closed by hand, and the project board understated progress — which was twice mis-attributed to
a missing keyword before anyone measured it.

| PR | keyword | merged by | issue outcome | lag |
|---|---|---|---|---|
| #687 | `Closes #674` | `ismailkattakath-ci[bot]` | stayed open → hand-closed | +2,263 s |
| #696 | `Closes #681` | `ismailkattakath-ci[bot]` | stayed open → hand-closed | +1,007 s |
| #698 | `Closes #677` | `ismailkattakath-ci[bot]` | stayed open | — |
| #697 | `Closes #682` | **`ismailkattakath` (human)** | **auto-closed** | **+1 s** |
| #700 | `Closes #657` | `ismailkattakath-ci[bot]` — **after the App grant** | **auto-closed** | **+2 s** |

Three bot merges with valid keywords closed nothing. One human merge closed in a second. One bot merge
*after* the fix closed in two. Nothing else changed between #698 and #700.

**Cause: GitHub closes a linked issue AS THE MERGING IDENTITY**, which for an auto-merge is the App — and
the App declared **no `issues` permission at all**, not even `read`:

```
$ gh api /apps/ismailkattakath-ci --jq '.permissions'      # BEFORE
{"actions":"write","contents":"write","metadata":"read",
 "organization_self_hosted_runners":"write","pull_requests":"write","workflows":"write"}
```

**That read is PUBLIC and needs no App JWT.** Two sessions spent hours inferring the cause from behaviour
while querying `/repos/{owner}/{repo}/installation` instead, which requires a JWT and 401s. The
authoritative view existed the whole time on a different endpoint.

**Fix: add `Issues: Write` to the App and accept the expansion on the installation.** No workflow change
was needed — `auto-merge.yml` requests no `permission-*` inputs, so its token inherits the installation's
full grant and the cure was live the moment the expansion was accepted.

### Two traps this left behind

**Narrowing the token must keep `issues: write`.** #679 originally asked to scope it to
`permission-pull-requests: write` *and nothing else*, which would have **cemented the bug** while reading
as a least-privilege win.

**And `enablePullRequestAutoMerge` needs `contents: write`** — the name does not suggest it and the docs
do not say it. The first narrowing dropped it and broke arming on its own PR:

```
GraphQL: Resource not accessible by integration (enablePullRequestAutoMerge)
```

So the minimum is three: `pull-requests: write`, `issues: write`, `contents: write`. A regression test
must assert **both** that arming succeeds *and* that the issue closes — a wrongly-scoped token still
mints fine, and arming precedes any merge, so either assertion alone is silent on the other's failure.

### A NEGATED keyword still closes — and the PR's own link list will not warn you

Two measured facts, both counter-intuitive, both of which cost an unintended state change here.

**1. `fix #N` fires even inside a sentence that denies it.** #713's commit message began:

```
Does NOT claim to fix #683's root cause.
```

GitHub matched `fix #683` and **closed #683**, two seconds after the merge — while the PR body said, in
as many words, *"#683 stays open. This gives it an evidence trail; it does not close it."* The scanner
reads the verb and the number; **the negation is invisible to it.** The sentence written to disclaim the
fix is the sentence that performed it.

**Backticks DO suppress it.** #697's body contained `` `Closes #674` `` inside a table describing
another PR's keyword, and `closingIssuesReferences` listed only its real target. So:

> To mention an issue without closing it: **wrap the reference in backticks**, or keep the verb away from
> the number — *"does not address the root cause of #683"*.

**2. `closingIssuesReferences` on the PR does NOT predict what a squash merge closes.** Measured on #713:

```
closes=EMPTY        squash=83629cf        -> and #683 closed anyway
```

The PR declared **no** closing link. The close came from the **squash commit message**, which GitHub
assembles from the PR body at merge time — so a keyword buried in body prose becomes a commit keyword
even though it never registered as a PR link.

That matters because the obvious pre-merge check is exactly the one that fails: querying the PR's closing
references is **not sufficient**. On a squash-merge repo, read the body as though it were the commit
message, because it is about to become one.

### Not the same as parent/child rollup

GitHub does **not** close a parent issue when its last sub-issue closes — measured on #655: all five
children `closed`, parent still `OPEN` 15 s later. That is an unrelated feature. A manual parent close is
not evidence of this defect returning.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| PR never arms; `arm auto-merge` job fails at the token step | CI bot App not installed on that repo, or the secret/var missing | Install the App on the repo; set `CI_BOT_APP_PRIVATE_KEY` + `CI_BOT_CLIENT_ID` |
| PR armed, checks green, never merges | Unresolved review thread (`required_review_thread_resolution`) | Resolve the thread |
| PR armed but never merges, no checks running | Real merge conflict — GitHub disarms it | Resolve and push; `synchronize` re-arms automatically |
| Drafted, marked ready, green, still unarmed | The draft conversion disarmed it (§3) and the ready transition's arm run did not land — the open tail of #683 | Confirm with `gh pr view <n> --json autoMergeRequest` **after** the arm run concludes; `gh pr ready` again, or arm by hand. Add the payload to #683 |
| Merged, but nothing published to FlakeHub | Something armed the PR with `GITHUB_TOKEN` | Restore the App token in `auto-merge.yml` |
| Someone else's PR auto-merged | The author guard was widened | The guard is a literal login; keep it that way |
| PR merges against a `main` that moved under it | Expected — `strict_required_status_checks_policy` is off by choice (§3) | The `push: main` leg catches it; fix forward |

## Turning it off

Delete `.github/workflows/auto-merge.yml` — PRs stop arming, everything else
unchanged. To go the other way and re-add a queue, read §3 "Before re-adopting a
queue" first: add the `merge_queue` rule to the ruleset, restore `merge_group:` to
`nix-ci.yml` and `gitleaks.yml`, and accept the second CI run.
