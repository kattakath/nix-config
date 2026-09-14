---
name: fleet-doctor
description: >
  Fleet-wide consistency sweep across every repo in the fleet manifest:
  stray branches/worktrees, unmerged PRs, red CI, stale
  flake.lock pins, Nix store garbage, and unactivated host generations
  (macos). Use when asked to "clean up the fleet", "sync everything",
  "is everything in sync", "garbage collect and activate", or after a
  multi-repo change (identity rename, secret rotation, cross-repo pin bump)
  that needs to land and propagate everywhere. Composes git-purity,
  pr-title, nix-hygiene (for nix-config itself), and the existing
  activate/GC tooling — not a replacement for any of them.
---

# fleet-doctor

**Problem this solves:** a change that starts in `nix-config` (e.g. a rename,
a secret rotation, a shared-input bump) has downstream effects across every
repo in the fleet manifest, both hosts, and the Nix store — branches to
clean up, PRs to land, pins to bump, generations to GC, hosts to
re-activate. Doing that by hand, repo by repo, is what this skill replaces.

## Fleet manifest

`.claude/skills/fleet-doctor/fleet-repos.txt` — one repo per line, relative
to `~/Developer`. This is the fleet — today exactly two lines, nix-config and
nix-personal — **not** every repo on disk; see the file's own header for every
removal and its reason.
Add a line there when a new fleet repo is created; nothing else in this skill
needs to change.

**The seven extracted satellites are gone from this list, on purpose.** ADR-002
absorbed each one into `nix-config` as a `modules/features/<name>/` capsule and
archived its repo, so sweeping it would report stale branches nobody can merge.
A satellite still on disk is a working copy that outlived its remote — do not
re-add it.

**Every listed repo is a flake now.** The manifest is down to the two composition
repos, so every flake-shaped step below (lock freshness, `nix flake check`) applies
to every member — there is no longer a flake-less member to skip.

**PENDING (2026-09-14): nix-personal is being DISSOLVED.** It is still cloned, still
pinned, still the sanctioned way macos is activated — so it stays in the manifest and
every step below still runs against it **today**. But it is shrinking fast (its
userscripts module and both gates, its private plugin marketplace, `leolistRag`,
`pageLabSites` and `leolist-crawlee` all came out on 2026-09-13/14), and the mechanisms it
used to own keep moving into this public repo under the shape/values contract — `activate`
itself became `packages/activate.nix` / `lib.mkActivateCli` here on 2026-09-13 (commit
b923914), leaving the private flake supplying values only.

**Two steps below die with it, and are flagged in place: D (cross-repo pin) and G (host
re-activation).** When the repo is actually gone, delete its manifest line *and* those two
steps. Do not leave either pointing at nothing, and do not invent a substitute command for
G — ask.

## Modes

1. **`audit`** — read-only: report findings, fix nothing. Triggered by
   "audit" / "report" / "status".
2. **`fix`** — audit, then apply everything in the **auto-fix** table below
   without asking per-repo (the command invocation itself is the explicit
   ask — same convention as `/hygiene fix`). Still stops and asks before
   anything in the **always confirm** table. **Default mode** when neither
   is specified.
3. **`scope <repo|host>`** — limit to one manifest entry (repo name) or one
   host (`macos`). Everything else is skipped and reported as such.

## Fix policy — read this before running `fix`

| Auto-fix (no per-repo prompt in `fix` mode) | Always confirm first |
|---|---|
| `git fetch --prune` (read-only) | Merging any PR, for any reason |
| `nix-collect-garbage -d` (host) | Deleting a branch/worktree with commits not on its remote/default branch |
| `nix flake lock --update-input <sibling>` + `nix flake check`, commit + push **only if check passes** | Committing/pushing anything that isn't this skill's own mechanical fix (stray WIP is reported, never committed) |
| Deleting a **local-only branch already merged into the repo's default branch** | Force-push, `git reset --hard`, `git clean -f`, any destructive git op |
| Re-running `nix fmt` / the repo's own format-fix on a repo already being touched | Reactivating a host when the guest/host is unreachable — report as skipped, don't retry-loop |
| Re-activating macos (`activate`) when its composing repos moved | Disk operations of any kind (`diskutil`, partitioning) |
| Nixpi: **disk-usage report only** — no GC/activation without an explicit ask (it's the live server; see `docs/nixpi-sd-flashing-runbook.md`) | Rotating secrets/tokens, editing `secrets/*.age`, anything with `secret set` |

These map onto the global Git Safety Protocol (never commit unless asked,
never force-push, never merge without explicit confirmation) — `fix` mode
never overrides that; it only pre-authorizes the specific mechanical,
easily-reversible fixes listed above, matching how this fleet was actually
brought into sync by hand in the session this skill was extracted from.

## Checklist (run in order)

### A. Per-repo: branches, worktrees, sync

Read the manifest, then for each repo run one consolidated pass rather than
one tool call per repo:

```bash
while read -r repo; do
  [ -z "$repo" ] && continue
  case "$repo" in \#*) continue ;; esac
  d="$HOME/Developer/$repo"
  [ -d "$d" ] || { echo "MISSING: $repo (not cloned locally)"; continue; }
  echo "=== $repo ==="
  git -C "$d" fetch --prune -q
  git -C "$d" status --porcelain          # dirty? never auto-touch this
  git -C "$d" branch                      # local branches — flag anything but the default
  git -C "$d" worktree list               # more than one entry is a finding
  def=$(git -C "$d" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##')
  git -C "$d" rev-list --left-right --count "origin/${def:-main}...${def:-main}" 2>/dev/null
done < .claude/skills/fleet-doctor/fleet-repos.txt
```

Findings: any local branch that isn't the default and has no unique commits
ahead of its remote counterpart → auto-fix (delete). Any branch/worktree
with unique unmerged commits, or any dirty `git status`, → report only.

### B. Per-repo: open PRs (GitHub repos only — nix-personal is GitLab, skip)

```bash
gh pr list --repo kattakath/<repo> --state open --json number,title,isDraft,mergeStateStatus,statusCheckRollup
```

Multiple open PRs are **normal** — each change gets its own PR and the merge
queue serializes them. Findings are: a PR whose title doesn't follow
[`pr-title.md`](../../rules/pr-title.md), a stale PR with no activity, or one
sitting on red CI. Report CI status per PR; never merge here regardless of
mode — see the confirm table above.

### C. Per-repo: latest CI run

```bash
gh run list --repo kattakath/<repo> --limit 1 --json workflowName,conclusion,createdAt,headBranch
```

A red/failed latest run is a finding, not an auto-fix — diagnosis is
repo/workflow-specific (see this session's Cachix-name and
`update-flake-lock` fixes as examples of "why generic auto-fix doesn't
work here"). Suggest a fork to investigate if the user wants it fixed now.

### D. Cross-repo pin freshness — **the only such pin; dies with nix-personal**

There is exactly **one** cross-repo pin in the fleet: `nix-personal` → `nix-config`.
It is real and worth checking **today** (last bumped 2026-09-14, commit aa1561e), but it
is the only operand this step has, so when nix-personal is dissolved the step becomes a
no-op and should be **deleted, not left sweeping an empty manifest**. Nothing pins
nix-config in the other direction. Still re-check `flake.nix` inputs against the manifest
before assuming a new case exists.

Compare the locked rev against `nix-config`'s current `origin/main` HEAD:

```bash
jq -r '.nodes["nix-config"].locked.rev' "$HOME/Developer/gitlab.com/ismailkattakath/nix-personal/flake.lock"
git -C "$HOME/Developer/github.com/kattakath/nix-config" rev-parse origin/main
```

Stale → auto-fix: `nix flake lock --update-input nix-config`, `nix flake
check`, and only if that passes: commit (message states old→new rev and
why) + push. If `nix flake check` fails after the bump, **stop, revert the
lock change, and report** — never leave a repo mid-bump.

### E. Nix-config's own hygiene

If nix-config itself is in scope, compose the **nix-hygiene** skill
(`.claude/skills/nix-hygiene/SKILL.md`) rather than re-deriving its
checklist here — run it in the same mode (`audit`/`fix`) fleet-doctor was
given.

### F. Garbage collection

```bash
# host
df -h / | tail -1
sudo nix-collect-garbage -d

# nixpi — report only, never collect without an explicit ask (live server)
```

### G. Host re-activation

Only if repos touched in this run actually compose macos (i.e. their
`flake.lock`/`flake.nix` changed) or the user asked for it directly:

```bash
# macos — ALWAYS via nix-personal's private composition, never
# `darwin-rebuild switch --flake .#macos` from nix-config directly (see
# memory: never-darwin-rebuild-from-public-repo) and never nix-config's own
# `nix run .#macos` (fleet-only baseline, drops the private layer).
cd "$HOME/Developer/gitlab.com/ismailkattakath/nix-personal" && activate
```

**This landing step is CORRECT TODAY and is on death row (2026-09-14).** `activate` is
still on PATH and still instantiated by nix-personal — but only with *values*: the CLI's
whole ~250-line body moved into this public repo on 2026-09-13 (commit b923914) as
`packages/activate.nix`, exported as `lib.mkActivateCli`. So the *mechanism* survives the
dissolution; the *instantiation on PATH* does not.

When nix-personal is gone and `activate` stops resolving: **stop and ask the operator
which command lands a generation now.** Do not substitute one on your own — in
particular, do not "fix" it to the public-repo rebuild banned in the comment above. That
ban exists because the failure it produced was silent, and nothing in an audit sweep is
worth guessing about an activation.

(The macvm guest and its tar-sync activation flow were removed 2026-09-05 —
docs/macvm-readd-runbook.md.)

## Report format (always end with this)

```markdown
## Fleet-doctor report
- **Mode:** audit | fix
- **Scope:** full fleet (N/N repos) | scoped to …
- **Branches/worktrees:** clean | findings: …
- **Open PRs:** none | repo #n — title — CI status — action (report only)
- **CI:** all green | repo — workflow — conclusion — needs investigation
- **Pins:** in sync | repo — bumped old→new, check ✅, pushed
- **GC:** host freed X | guest freed Y (or skipped, VM down) | nixpi: N free (report only)
- **Hosts:** macos re-activated | skipped (why)
- **Verdict:** CLEAN | FIXED (list what) | NEEDS ATTENTION (why, and what needs a human decision)
```

## Compose with existing automation

```
/fleet-doctor [audit|fix] [scope]   → this skill
/hygiene [scope]                     → nix-config's own LEAN/DRY pass (composed by step E)
/eval                                → nix-config eval only, no cross-repo scope
gh pr list / gh run list             → what this skill's B/C steps wrap
```

A lightweight SessionStart nudge (`.claude/hooks/fleet-doctor-digest.js`)
reminds you to run this when it's been a while — see that file for the
threshold. It never runs checks itself, only reads a local timestamp.
