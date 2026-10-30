# Landing a change — wait in the background, push docs straight to `main`

Unscoped on purpose, like `pr-title.md`: it governs the END of every session, whatever the
session touched. Evidence for every lever here:
[`docs/pr-wait-research.md`](../../docs/pr-wait-research.md) (levers #1, #5, #6). A change that
depends on an unmerged one never waits for it to merge: `pr-title.md` § One PR per change.

## 1. Never poll CI inside a turn

**The armed auto-merge IS the wait.** After `gh pr create`, `auto-merge.yml` arms the PR and
GitHub lands it the moment the required checks go green. Nothing in your turn speeds that up.

- **Never** in the foreground: a `sleep` loop, `gh pr checks --watch`, `gh run watch`, or
  re-running `gh pr view` / `gh run list` to see whether it moved.
- **Need the outcome** (an `activate` or a Pi deploy after merge, or a follow-up that must
  know)? Start ONE watch in the BACKGROUND (`run_in_background: true`, or Monitor), then go
  on with other work or end the turn. For example:
  `gh pr checks <n> --required --watch --fail-fast --interval 60`, then
  `gh pr view <n> --json state,mergedAt`.
- **Report on only two outcomes:** **RED** (name the failing check and its run URL) or
  **MERGED, needs `activate`** (or a deploy). A merge that needs nothing earns one line in
  the final answer, not a status report.
- **`autoMergeRequest` races its own workflow.** Read `gh pr view <n> --json autoMergeRequest`
  only AFTER the arm run concludes. Read seconds after `gh pr create` (#747, 2026-10-02) it is
  `null`, and a not-yet-run arm looks exactly like a skipped one. That check belongs INSIDE
  the background watch: wait until `gh run list --workflow auto-merge.yml --limit 1 --json
  conclusion` is not `null`.

Why: the general rule and its census are the global `claude/CLAUDE.md` § CI waits
(evidence: `docs/pr-wait-research.md` lever #1). The bullets stay here too, because a session
with no installed global context (devcontainer, Codespaces) never loads that file.

## 2. Docs / `.claude`-only changes may go straight to `main`

The permission comes from the global CLAUDE.md § "On repos Ismail owns". The mechanism is
the `protect-main` ruleset: the Repository Admin role has `bypass_mode: always` (read with
`gh api repos/kattakath/nix-config/rulesets/<id>`, 2026-10-18). This section owns only
**which paths qualify** and **the gate**.

**Qualifies only if EVERY changed path is in the allowlist.** That includes both sides of a
rename and every deletion. Allowed: `docs/**`, a repo-root `*.md`, and `.claude/**`.
Never allowed: any `.nix` (in any directory). This prints the paths that DISQUALIFY, so it
must print nothing:

```bash
git fetch origin && git rebase origin/main
git diff --name-only --no-renames origin/main HEAD | awk '/\.nix$/ || !/^(docs\/|\.claude\/|[^\/]+\.md$)/'
```

**Where the line is.** Docs and `.claude/` are read only by `checks` (for example
`claude-md-budget` and `rule1d-guard-knows-the-pi` read them with `readFile`). No host
toplevel reads them, so a direct push cannot change what any host BUILDS. Each exclusion
below fails that test:

| Path | Why it needs a PR |
|---|---|
| `claude/**` | the global CLAUDE.md and rules go into the home closure (`programs.claude-code.context` in `modules/home/default.nix`; the rule via `programs.claude-code.rules` in `claude-brain.nix`) |
| `sites/**` | a directory literal, copied into nixpi's LIVE closure |
| `.github/**` | a workflow is proven only by the run it changes |
| `flake.lock`, `*.nix`, `packages/`, `scripts/`, `ast-grep/`, `secrets/` | these are the build itself |

**The gate is the ruleset's three required checks, run locally on the rebased HEAD:**

| Required check | Local equivalent |
|---|---|
| `required-checks` | `nix flake check`. It covers `pre-commit` (gitleaks over the tree, plus treefmt), `claude-md-budget`, `line-refs-cite-constructs`, `docs-indexed` and `docs-links-resolve` |
| `Scan for secrets` | `nix develop -c gitleaks git --log-opts="origin/main..HEAD" --redact --no-banner` scans every unpushed COMMIT. The push publishes each one, so a secret that one commit added and a later one removed still leaks |
| `Lint .claude config` (when `.claude/` or any `CLAUDE.md` changed — cclint's `context` lints CLAUDE.md, and CI runs it on every PR) | both `run:` steps of `.github/workflows/claude-config-lint.yml`, VERBATIM from that file: three `cclint` lines plus every `.claude/hooks/tests/*.sh` |

Then push: `git push origin HEAD:main`. It must be a fast-forward — no force of any kind in
this lane, `--force-with-lease` included. (`claude-guardrails.nix` denies only bare
`--force`/`-f`; the lease form stays allowed for an agent's own PR branch, never for `main`.) The post-push CI on `main` is the backstop, and a RED
there gets fixed forward in a PR. Watch it in the background, per §1.

**Not a commit hook.** gitleaks runs inside `nix flake check`. The devShell installs no git
hooks on purpose (`modules/parts/devshell.nix`, shellHook comment), so skipping the gate
skips the scan.

If any path or any gate step fails, open a normal PR (`pr-title.md`). **A worktree-isolated
session cannot run the whole gate.** Its Bash guard refuses `nix develop -c gitleaks git …` and
`bash .claude/hooks/tests/*.sh` as unprovable git (measured 2026-10-18), so it takes the PR
lane. Never word around the guard to reach a direct push.
