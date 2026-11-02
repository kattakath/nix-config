# ADR-010 — Scheduled agent runs: one pane, three lanes

**Status:** **DECIDED 2026-11-01.** Research only; no code changes. It records which mechanism
a recurring Claude run uses, so that each new job does not re-open the question or invent a
scheduler.

**Question.** Several recurring jobs (an evidence refresh for a job-search repo, monthly cost
reports, ledger syncs, follow-up chasers) want to run headlessly on a schedule. Is there an
official or community-standard place where all scheduled Claude runs are listed and managed,
instead of a hand-rolled launchd agent per job?

## 1. Verdict

- **Yes: Claude Desktop's *Scheduled* page.** It lists **local** scheduled tasks (run on this
  Mac, with its files, tools and MCP servers) and **cloud** scheduled tasks (formerly
  *routines*) in one pane, with Run now, Pause, Edit, per-run history including skipped runs,
  and per-task permission approvals. The operator already runs six tasks there (census
  2026-11-01: `~/.claude/scheduled-tasks/`).
- **No official pane covers everything.** launchd jobs, GitHub Actions schedules and `/loop`
  stay outside it. The community dashboards that wrap `claude -p` are a second pane, which is
  the reinvented wheel this ADR rejects.

## 2. The options, as documented

| Mechanism | Runs on | Local files / localhost DB / Drive for Desktop | Central view | Maturity, plan |
|---|---|---|---|---|
| **Desktop local task** | this Mac, app open and awake | **yes** (one working folder; optional per-run worktree) | **Desktop → Scheduled** | GA; Desktop ≥ 1.1.5368 |
| Cloud task (routine) | Anthropic cloud | **no** — "fresh clone" | same pane + claude.ai/code/routines, `/schedule` | research preview; ≥ 1 h interval; 100 runs/h |
| Self-hosted environment | a runner you host | network yes; repos only as GitHub clones | admin *Cloud environments* page | public beta, **Team/Enterprise only**, off by default |
| `claude -p` + launchd | this Mac, app closed | yes | **none** — build your own | CLI documented; Anthropic gives no launchd guidance |
| GitHub Actions `schedule:` | GitHub runners | no (GitHub clone) | per-repo Actions tab | GA; public-repo schedules disabled after 60 inactive days |
| `/loop` / `CronCreate` | an open session | yes | `CronList`, per session | session-scoped; recurring tasks expire after 7 days |
| Community: codegeass, claude-code-scheduler, claude-tasks, claun | this Mac, wrapping `claude -p` | yes | their own dashboards | third-party; several pass `--dangerously-skip-permissions` |

Sources: [Desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks),
[cloud scheduled tasks](https://code.claude.com/docs/en/routines),
[self-hosted environments](https://code.claude.com/docs/en/self-hosted-environments),
[headless](https://code.claude.com/docs/en/headless),
[GitHub Actions](https://code.claude.com/docs/en/github-actions),
[`/loop`](https://code.claude.com/docs/en/scheduled-tasks).

## 3. Decision — three lanes, one pane

1. **Default: Desktop local task.** Any job that needs this Mac — local repos, the local
   pgvector store, Drive for Desktop, page-lab Chromium, the login Keychain.
2. **Cloud task** for jobs that need only connectors and GitHub (inbox triage, PR digests), so
   they run with the Mac off. Same pane.
3. **launchd + `claude -p` only as the exception**, for a job that must run while the Desktop
   app is closed. Declare it in Nix like every other launchd unit (`launchd-naming`,
   `modules/darwin/logging.nix`), and `launchd-doctor` is its pane.

**Rejected:** community schedulers (a second pane to drift, and the permission-skip default);
GitHub cron for local work (no local access); self-hosted environments (plan-gated, and
GitHub-clone-only, so neither unpushed work nor Drive is visible).

## 4. What the default lane costs — recorded, not fixed

| Gap | Consequence | Mitigation |
|---|---|---|
| Fires only while the Desktop app is open and the Mac awake | A run whose window passes with the Mac asleep is skipped; on wake, Desktop runs **one** catch-up for the most recent miss within **7 days** and drops older ones | *Keep computer awake* in Desktop settings; schedule early in a period; the task prompt must tolerate a late run |
| **Not declarative**: only the prompt is a file (`~/.claude/scheduled-tasks/<name>/SKILL.md`); schedule, folder, model and enabled state live in the app | Breaks this repo's everything-in-Nix rule; a reset Mac loses the schedules | Accepted. Home Manager could own the prompt text, never the schedule. A rebuild recreates tasks through the app |
| Desktop is a windowed app that must stay running | Conflicts with a quiet login | Operator's call; the launchd lane exists for jobs that must not depend on it |
| A run in Manual permission mode stalls on an unanswered prompt | Silent no-op | After creating a task: **Run now** once and *always allow* each prompt; later runs auto-approve the same tools |
| **Deletion is UI-only**: the Delete button removes the task, and the `SKILL.md` folder stays on disk | Folders of finished one-offs accumulate | Delete in the app first, then remove the folder |

## 5. Weakest assumption

That the operator keeps Claude Desktop running. If a quiet login wins over that, the default
flips to lane 3, and the cost moves to writing one Nix-declared launchd unit per job, with no
shared pane beyond `launchd-doctor`.
