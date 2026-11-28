# ADR-019 — One named background session per Claude Code project

**Status:** **DECIDED 2026-11-28.** The operator chose three things: scaffold committed files,
a session for every repo on sight, and this ADR first, then the build. The build lands in
`kattakath/skills` (plugin `project-sessions`, plus an upgrade to `slack-etiquette`). This repo keeps
only the residue in § 4.

**Question.** How should the default interactive `claude` session guarantee two things for every
git repo it works on? (1) The repo is a valid Claude Code project. (2) The work goes to one named,
background, Remote Control session per project, which shows that project's own saved task list.
The design must use Claude Code's own features and stay invisible to other developers.

## 1. Evidence: what Claude Code 2.1.330 does (measured 2026-11-28)

| Need | Feature | Result |
|---|---|---|
| Create a background session | `claude --bg --name N "<prompt>"` | Works. `:` and `/` are accepted in N |
| Unique names | none | **Not enforced.** Two sessions with the same name both start. `claude logs N` then answers "2 sessions match … Use the id" |
| Resume the same session | `claude --bg --resume <full lowercase sessionId>`, **no other flag** | Same id, name kept |
| Resume by name, short id, or with any flag | same command | **Starts a copy.** By name, the copy also loses the name (it gets an auto name) |
| Remote Control | `remoteControlAtStartup: true` | Background sessions connect on their own |
| Task list | `CLAUDE_CODE_TASK_LIST_ID` set when the session is created | The list is shown, and it survives a bare resume without the variable. Its folder replaces every character outside `[A-Za-z0-9_-]` with `-`, which loses information: `a/b-c` and `a-b/c` share one list |
| Root context | user `CLAUDE.md`, settings, plugins, hooks | All load in a background session |
| Address it | `SendMessage` by name | Delivered, and the reply comes back. A session in a different permission mode holds the message for approval instead |
| Workspace trust | — | `--bg` **refuses an untrusted folder**, and a trusted parent does not cover it. Each new repo needs one trust click from the operator |
| Pin | agent view, Ctrl+T | **No CLI flag.** Pinning stays manual |
| "Always delegate" setting | — | None. Delegation has to come from an instruction or a hook |
| Minimal valid project | — | Nothing is required. Validators: `claude plugin validate`, the schemastore settings schema |

## 2. Decision

- **Name.** `<host>:<owner>/<repo>` from `git remote get-url origin`, for example
  `github.com:kattakath/nix-config`. A repo with no remote is named after its realpath. The name is a
  label, not a key.
- **Create or resume.** Only the plugin's `bin/project-session ensure` may create these sessions.
  Under a lock it reads `claude agents --json --all` and matches the exact name **and** the repo's
  `git rev-parse --git-common-dir` realpath, so worktrees and symlinks map to one repo. Then:
  - a live match: the main session talks to it with `SendMessage`;
  - a stopped match: it resumes with the bare full session id;
  - no match: it creates the session with the task-list variable set to the name.
  It reports duplicates and never kills one. **No id is stored or shown.** Each call reads the
  id again.
- **When.** On sight: the first time the main session works in a repo.
- **Project scaffold.** The doctor validates the Claude files a repo already has. Where the repo has
  none, it scaffolds the standard committed shape: `CLAUDE.md` via `/init` and `.claude/settings.json`
  carrying `$schema`. Both files contain only content any developer could have written. **Nothing in
  them names this setup, its plugins or its marketplace.** Those come from user scope. A commit to a
  repo the operator does not own still needs his yes (**gates**).
- **Slack.** The send rules stay in `slack-etiquette`, with no second copy. Before posting it reads
  the signed-in profile to confirm the workspace, then looks people and channels up live. A
  PreToolUse hook on the tool-name **suffix** (`slack_send_message`, `_draft`, `schedule_message`)
  covers every connector prefix.
- **Dropped:** a coordinator session (`houston`), a send-only session (`courier`), the Linear
  integration, a workspace-file generator, and any copy of the global motto.

## 3. Rejected options

| Option | Why it lost |
|---|---|
| Resume by name | It starts a copy and drops the name, which makes duplicates (measured) |
| Store a name → id map | It is a second copy of state that `claude agents` already holds (**one source**) |
| Write `~/.claude/jobs/pins.json` | Internal state, not a documented interface |
| Nix, a flake or `.envrc` in every repo | A preset toolchain forced on someone else's repo; that killed `empire` |
| New marketplace repo | It would duplicate the release machinery of `kattakath/skills` |
| All of it in nix-config | Doesn't reach the devcontainer or teammates; every change needs an `activate` |
| Subagents instead of sessions | No per-project session visible over Remote Control |

## 4. What stays in this repo

- The plugin id in `modules/home/claude-plugins.nix`.
- Declared settings: `remoteControlAtStartup`, plus the task-tool environment.
- One line in `claude/CLAUDE.md` that points at the skill. The procedure lives only in the skill.

## 5. Weakest assumption, and how to settle it

- **The assumption:** a skill plus a SessionStart hook makes the main session delegate reliably.
  `empire` died with zero triggers.
- **How to settle it:** before the `CLAUDE.md` line is upgraded to MUST, run a 10-session eval with
  multi-repo tasks and count `ensure` calls.
- **Known gaps:**
  - Pinning stays manual.
  - Each new repo needs a trust click.
  - Two lossy names can share one task list; the doctor reports it.
  - On-sight creation leaves an idle process for each repo.
