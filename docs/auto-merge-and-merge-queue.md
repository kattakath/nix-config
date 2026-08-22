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

## The three pieces

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
`vars.CI_BOT_CLIENT_ID` and `secrets.CI_BOT_APP_PRIVATE_KEY`.

### 2. `merge_queue` rule on `main` — orders the merges

Configured as a **ruleset** rule (`"type": "merge_queue"`), `merge_method: SQUASH`,
`grouping_strategy: ALLGREEN`.

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
| `ismailkattakath/nix-keychain-secrets` | `checks` | `ci.yml` |
| `ismailkattakath/nix-firmware-secrets` | `checks` | `ci.yml` |
| `ismailkattakath/nix-local-rag` | `checks` | `ci.yml` |
| `ismailkattakath/nix-mcp-gateway` | `checks` | `ci.yml` |
| `ismailkattakath/nix-cloudflared-connector` | `checks` | `ci.yml` |
| `ismailkattakath/nix-vast-provision` | `checks` | `ci.yml` |
| `ismailkattakath/ircc-whatsapp-bot` | `checks` | `ci.yml` |

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
| Merged, but nothing published to FlakeHub | Something armed the PR with `GITHUB_TOKEN` | Restore the App token in `auto-merge.yml` |
| Someone else's PR auto-merged | The author guard was widened | The guard is a literal login; keep it that way |

## Turning it off

Per repo, cheapest first: delete `.github/workflows/auto-merge.yml` (PRs stop
arming, everything else unchanged) → remove the `merge_queue` rule from the ruleset
(back to plain auto-merge; re-enable `strict_required_status_checks_policy` if the
up-to-date guarantee is still wanted) → drop the `merge_group:` triggers.
