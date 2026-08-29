# Auto-merge + merge queue across the flake fleet

Every flake this operator owns merges itself once CI is green — **provided the PR
is authored by `ismailkattakath`**. Nothing here bypasses a gate: the PR still has
to satisfy the same required status checks it always did. What is removed is the
manual "Merge" click and the manual "Update branch" click.

Three pieces have to line up in each repo. Miss one and PRs sit armed forever.

```
  PR opened by ismailkattakath
        |
        v
  auto-merge.yml  --(CI bot App token)-->  gh pr merge --auto --squash
        |
        v
  merge_queue rule on main  -->  entry built on gh-readonly-queue/main/...
        |                              |
        |                        merge_group trigger in the CI workflow
        v                              |
   required checks green  <------------+
        |
        v
      merged to main  -->  push:main workflows still fire (App token, not GITHUB_TOKEN)
```

## The four pieces

### 1. `auto-merge.yml` — arms the PR

A `pull_request`-triggered workflow that runs `gh pr merge --auto --squash` when
`github.event.pull_request.user.login == 'ismailkattakath'` and the PR is not a
draft. Re-fires on `synchronize`, so a PR the queue ejected (conflict, failed queue
build) re-arms itself the moment the fix is pushed.

It authenticates with an **installation token from the CI bot GitHub App**, never
`GITHUB_TOKEN`. Auto-merge attributes the merge to whoever armed it, and events
produced by `GITHUB_TOKEN` do not start workflow runs — arming with it would land
every auto-merged PR on `main` silently, killing `flakehub-publish.yml` and
`build-installers.yml`. This is the single most important detail on this page.

Requires per repo: the App **installed on that repository**, plus
`vars.CI_BOT_CLIENT_ID` and `secrets.CI_BOT_APP_PRIVATE_KEY`. Both are supplied
**org-wide** on `kattakath` rather than per repo — the `kattakath-ci` App is
installed on the org with `repository_selection: all`, and the client id is an org
variable (visibility: all). A new flake in this org therefore inherits everything
except its own `auto-merge.yml`.

Note that **repository secrets do not survive a repo transfer** (variables and
branch protection do). Anything moved into the org needs its secrets re-set.

### 2. `merge_queue` rule on `main` — orders the merges

Configured as a **ruleset** rule (`"type": "merge_queue"`), `merge_method: SQUASH`,
`grouping_strategy: ALLGREEN`.

**Merge queue is organization-only.** `POST /repos/{owner}/{repo}/rulesets` rejects
the rule outright on a repository owned by a USER account — `422 Validation Failed,
Invalid rule 'merge_queue'` — with no hint that ownership is the cause. This is why
all seven satellite flakes were moved off the `ismailkattakath` user account into
the `kattakath` org. A GitHub **Free** org is enough, for public repos.

Why a queue at all: these repos require branches to be up to date before merging.
Plain auto-merge does **not** update a stale head branch, so with two PRs open the
second waits forever behind the first. The queue tests each entry against the
projected merged result instead, and per GitHub "does not require a pull request
author to update their pull request branch and wait for status checks to finish
before trying to merge".

Because the queue subsumes it, `strict_required_status_checks_policy` (require
branches up to date) is turned **off** wherever the queue is on — leaving both on
re-introduces exactly the stall the queue removes.

### 3. `merge_group:` in every REQUIRED CI workflow — reports on the entry

A queue entry is built on its own `gh-readonly-queue/main/...` ref, which emits
**neither `pull_request` nor `push`**. A required check whose workflow lacks a
`merge_group:` trigger therefore never reports on the entry, and the merge times
out (`check_response_timeout_minutes`). Every workflow producing a **required
context** needs the trigger; non-required ones (`claude-config-lint`,
`build-devcontainer`) deliberately do not, so they cost nothing per queue entry.

In this repo that means `nix-ci.yml` (`required-checks`) and `gitleaks.yml`
(`Scan for secrets`).

### 4. Rules the queue app must satisfy ON ITS OWN

The queue does not merge as *you*. Clicking **Merge when ready** hands the merge to
the **GitHub Merge Queue** app, which re-evaluates the ruleset **as itself** — and it
is not in `bypass_actors`. A Repository-admin bypass does not transfer to it.

So every rule in `protect-main` must be satisfiable by the PR *without* a bypass. A
rule the queue cannot satisfy is GitHub's documented removal reason **"branch
protection failure that could not automatically be resolved"**, and it fires
**instantly**, before a merge group exists. That looks nothing like the §3 timeout:

| | `merge_group:` missing (§3) | rule the queue can't satisfy |
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

**Concretely, 2026-08-29.** The `merge_queue` rule was added to `protect-main` on
2026-08-22T16:28Z — 13 minutes after the last Dependabot PR merged, so no bot PR had
ever met the queue. `protect-main` already carried
`require_extra_approval_for_unattributed_changes: true`, inert while
`required_approving_review_count` is `0` and no queue existed. The first Dependabot PR
to reach the queue (#316) was ejected after **14 s**: the rule raises an agent-authored
PR to one required approval, it had zero, and the queue cannot self-approve. Fixed by
setting the flag `false` across all nine queue-carrying repos — with required approvals
already `0` it can only ever block, never gate.

Audit any repo before adding a rule:

```bash
gh api repos/kattakath/<repo>/rulesets/<id> --jq '{bypass: .bypass_actors, pr: (.rules[] | select(.type=="pull_request") | .parameters)}'
```

## Cost

One extra CI run per merge — the queue entry is built separately from the PR. That
is the price of the queue's correctness guarantee and is unavoidable while
"branches up to date" semantics are wanted. It is also why `build-installers.yml`
is deliberately **not** a required check: its non-cancellable runs would otherwise
be duplicated on every queue entry (see `.claude/rules/pr-consolidation.md`).

## The fleet

| Repo | Required context(s) | CI workflow needing `merge_group:` |
| --- | --- | --- |
| `kattakath/nix-config` | `required-checks`, `Scan for secrets` | `nix-ci.yml`, `gitleaks.yml` |
| `kattakath/nix-keychain-secrets` | `checks` | `ci.yml` |
| `kattakath/nix-firmware-secrets` | `checks` | `ci.yml` |
| `kattakath/nix-local-rag` | `checks` | `ci.yml` |
| `kattakath/nix-mcp-gateway` | `checks` | `ci.yml` |
| `kattakath/nix-cloudflared-connector` | `checks` | `ci.yml` |
| `kattakath/nix-vast-provision` | `checks` | `ci.yml` |
| `kattakath/ircc-whatsapp-bot` | `checks` | `ci.yml` |

All eight are public and org-owned, which is what makes the queue available.

The private `ismailkattakath/nix-personal` (GitLab) is **out of scope**: it has no
`.gitlab-ci.yml` at all, so there is no pipeline for a merge-when-green rule to
wait on. GitLab's equivalent is "merge when pipeline succeeds" plus
`only_allow_merge_if_pipeline_succeeds` — both meaningless until that repo has CI.

## Failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| PR never arms; `arm auto-merge` job fails at the token step | CI bot App not installed on that repo, or the secret/var missing | Install the App on the repo; set `CI_BOT_APP_PRIVATE_KEY` + `CI_BOT_CLIENT_ID` |
| PR arms, queue entry hangs, then times out | A required workflow lacks `merge_group:` | Add the trigger to that workflow |
| PR armed but never enters the queue | Real merge conflict — GitHub ejects it | Resolve and push; `synchronize` re-arms automatically |
| PR enters the queue, ejected ~15 s later, queue page empty | A ruleset rule the **queue app** cannot satisfy without a bypass (§4) | Relax the rule, or add `GitHub Merge Queue` to `bypass_actors` |
| Merged, but nothing published to FlakeHub | Something armed the PR with `GITHUB_TOKEN` | Restore the App token in `auto-merge.yml` |
| Someone else's PR auto-merged | The author guard was widened | The guard is a literal login; keep it that way |

## Turning it off

Per repo, cheapest first: delete `.github/workflows/auto-merge.yml` (PRs stop
arming, everything else unchanged) → remove the `merge_queue` rule from the ruleset
(back to plain auto-merge; re-enable `strict_required_status_checks_policy` if the
up-to-date guarantee is still wanted) → drop the `merge_group:` triggers.
