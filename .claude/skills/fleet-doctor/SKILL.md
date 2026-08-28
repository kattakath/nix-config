---
name: fleet-doctor
description: >
  Fleet-wide consistency sweep across every repo in the fleet manifest:
  stray branches/worktrees, unmerged/unconsolidated PRs, red CI, stale
  flake.lock pins, Nix store garbage, and unactivated host generations
  (macos, macvm). Use when asked to "clean up the fleet", "sync everything",
  "is everything in sync", "garbage collect and activate", or after a
  multi-repo change (identity rename, secret rotation, cross-repo pin bump)
  that needs to land and propagate everywhere. Composes git-purity,
  pr-consolidation, nix-hygiene (for nix-config itself), and the existing
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
to `~/Developer`. This is the fleet (nix-config + nix-personal + every
extracted satellite flake), **not** every repo on disk — see the file's own
header. Add a line there when a new flake is extracted; nothing else in this
skill needs to change.

## Modes

1. **`audit`** — read-only: report findings, fix nothing. Triggered by
   "audit" / "report" / "status".
2. **`fix`** — audit, then apply everything in the **auto-fix** table below
   without asking per-repo (the command invocation itself is the explicit
   ask — same convention as `/hygiene fix`). Still stops and asks before
   anything in the **always confirm** table. **Default mode** when neither
   is specified.
3. **`scope <repo|host>`** — limit to one manifest entry (repo name) or one
   host (`macos`, `macvm`). Everything else is skipped and reported as such.

## Fix policy — read this before running `fix`

| Auto-fix (no per-repo prompt in `fix` mode) | Always confirm first |
|---|---|
| `git fetch --prune` (read-only) | Merging any PR, for any reason |
| `nix-collect-garbage -d` (host + reachable guest) | Deleting a branch/worktree with commits not on its remote/default branch |
| `nix flake lock --update-input <sibling>` + `nix flake check`, commit + push **only if check passes** | Committing/pushing anything that isn't this skill's own mechanical fix (stray WIP is reported, never committed) |
| Deleting a **local-only branch already merged into the repo's default branch** | Force-push, `git reset --hard`, `git clean -f`, any destructive git op |
| Re-running `nix fmt` / the repo's own format-fix on a repo already being touched | Reactivating a host when the guest/host is unreachable — report as skipped, don't retry-loop |
| Re-activating macos (`nrs`/`activate`) and macvm (tar-sync + guest `nix run …#macvm`) when their composing repos moved | Disk operations of any kind (Tart disk resize, `diskutil`, anything from the 2026-08-27 macvm incident) |
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

Apply [`pr-consolidation.md`](../../rules/pr-consolidation.md): more than one
open PR from the same session/author is a finding, never auto-merged. Report
CI status per PR; never merge here regardless of mode — see the confirm
table above.

### C. Per-repo: latest CI run

```bash
gh run list --repo kattakath/<repo> --limit 1 --json workflowName,conclusion,createdAt,headBranch
```

A red/failed latest run is a finding, not an auto-fix — diagnosis is
repo/workflow-specific (see this session's Cachix-name and
`update-flake-lock` fixes as examples of "why generic auto-fix doesn't
work here"). Suggest a fork to investigate if the user wants it fixed now.

### D. Cross-repo pin freshness

Repos whose `flake.lock` pins another fleet repo as an input (today:
`nix-personal` → `nix-config`; check others' `flake.nix` inputs against the
manifest for new cases) — compare the locked rev against that repo's current
`origin/<default>` HEAD:

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

# macvm guest — only if reachable; non-fatal skip otherwise
nix run "$HOME/Developer/github.com/kattakath/nix-config#macvm-tart-doctor" \
  | grep -q '^state: running' && \
  nix run "$HOME/Developer/github.com/kattakath/nix-config#macvm-tart-ssh" -- \
    'df -h / | tail -1; sudo nix-collect-garbage -d'

# nixpi — report only, never collect without an explicit ask (live server)
```

### G. Host re-activation

Only if repos touched in this run actually compose macos/macvm (i.e. their
`flake.lock`/`flake.nix` changed) or the user asked for it directly:

```bash
# macos — ALWAYS via nix-personal's private composition, never
# `darwin-rebuild switch --flake .#macos` from nix-config directly (see
# memory: never-darwin-rebuild-from-public-repo) and never nix-config's own
# `nix run .#macos` (fleet-only baseline, drops the private layer).
cd "$HOME/Developer/gitlab.com/ismailkattakath/nix-personal" && activate

# macvm — sync nix-personal in (guest has no GitLab SSH), then activate
# through the SAME private composition (macvm has real private modules:
# claudeBrain, civitaiLiveWallpaper — the fleet-only bootstrap path drops
# them, same trap as macos above).
NP="$HOME/Developer/gitlab.com/ismailkattakath/nix-personal"
CFG="$HOME/Developer/github.com/kattakath/nix-config"
tar -C "$NP" --exclude result --exclude .direnv -cf - . |
  nix run "$CFG#macvm-tart-ssh" -- 'mkdir -p ~/nix-personal && tar -C ~/nix-personal -xf -'
nix run "$CFG#macvm-tart-ssh" -- 'nix run /Users/ismail/nix-personal#macvm'
```

Skip non-fatally (report "skipped — VM not running") if macvm can't be
reached; never retry-loop waiting for it.

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
- **Hosts:** macos re-activated | macvm re-activated | skipped (why)
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
