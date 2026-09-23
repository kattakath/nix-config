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
to `~/Developer`. This is the fleet — today exactly **one** line, nix-config
itself — **not** every repo on disk; see the file's own header for every
removal and its reason.
Add a line there when a new fleet repo is created; nothing else in this skill
needs to change.

**The seven extracted satellites are gone from this list, on purpose.** ADR-002
absorbed each one into `nix-config` as a `modules/features/<name>/` capsule and
archived its repo, so sweeping it would report stale branches nobody can merge.
A satellite still on disk is a working copy that outlived its remote — do not
re-add it.

**`nix-personal` is RETIRED (2026-09-15).** Every value it held is folded directly into
this repo (`hosts/macos.nix`, `modules/parts/identity.nix`). Steps D (cross-repo pin) and
G (host re-activation) below were the two that existed only to serve it — both collapsed
to match.

`activate` did NOT go with it. The CLI that was retired was nix-personal's
freshness-gated one; this repo grew its own the same day (`packages/activate.nix`,
114c9a4) and it is the activation command CLAUDE.md names — a self-elevating
`darwin-rebuild switch` that works from any directory and prints the flake dir and
branch@rev before it builds. Step F below already runs it.

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
| Reporting host disk usage (`df -h /nix`) — collection is automatic now, see step E | Deleting a branch/worktree with commits not on its remote/default branch |
| `nix flake lock --update-input <sibling>` + `nix flake check`, commit + push **only if check passes** | Committing/pushing anything that isn't this skill's own mechanical fix (stray WIP is reported, never committed) |
| Deleting a **local-only branch already merged into the repo's default branch** | Force-push, `git reset --hard`, `git clean -f`, any destructive git op |
| Re-running `nix fmt` / the repo's own format-fix on a repo already being touched | Reactivating a host when the guest/host is unreachable — report as skipped, don't retry-loop |
| Re-activating macos (`activate`) when its composing repos moved | Disk operations of any kind (`diskutil`, partitioning) |
| Nixpi: **disk-usage report only** — no GC/activation without an explicit ask (it's the live server; see `docs/nixpi-sd-flashing-runbook.md`) | Rotating secrets/tokens, editing `secrets/*.age`, anything with `secret set` |
| — | `sudo nix-collect-garbage -d` on the host — determinate-nixd collects in the background on macos (on nixpi its collector is `disabled` and the weekly `nix.gc` timer collects — `modules/nixos/core.nix`), and `-d` drops **every** old generation, leaving no rollback target |

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

### B. Per-repo: open PRs

```bash
gh pr list --repo kattakath/<repo> --state open \
  --json number,title,isDraft,mergeStateStatus,statusCheckRollup,autoMergeRequest
```

Multiple open PRs are **normal** — each change gets its own PR and a single CI
gate lands them independently. (The merge queue that used to serialize them was
removed 2026-09-22 — [`auto-merge-and-merge-queue.md`](../../../docs/auto-merge-and-merge-queue.md).)

Findings are: a PR whose title doesn't follow
[`pr-title.md`](../../rules/pr-title.md), a stale PR with no activity, one
sitting on red CI, or one **never armed** — `autoMergeRequest == null` on a
non-draft PR means `auto-merge.yml` did not arm it and it will sit open
forever. A DRAFT with `autoMergeRequest` set is fine: arming survives the draft
state and releases on `ready_for_review` (observed on #559, 2026-09-22).

Read `autoMergeRequest.enabledBy.login`, not just the field's presence: it must
be `app/ismailkattakath-ci`. Anything armed by `github-actions` means something
used `GITHUB_TOKEN` — which merges SILENTLY and stops every `push: main`
workflow from firing, the failure that doc calls its single most important
detail. That is a finding even though the PR looks healthy.

Report CI status per PR; never merge here regardless of mode — see the confirm
table above.

### C. Per-repo: latest CI run

```bash
gh run list --repo kattakath/<repo> --limit 1 --json workflowName,conclusion,createdAt,headBranch
```

A red/failed latest run is a finding, not an auto-fix — diagnosis is
repo/workflow-specific (see this session's Cachix-name and
`update-flake-lock` fixes as examples of "why generic auto-fix doesn't
work here"). Suggest a fork to investigate if the user wants it fixed now.

### D. Nix-config's own hygiene

If nix-config itself is in scope, compose the **nix-hygiene** skill
(`.claude/skills/nix-hygiene/SKILL.md`) rather than re-deriving its
checklist here — run it in the same mode (`audit`/`fix`) fleet-doctor was
given.

### E. Garbage collection

**macos collects itself now.** `determinateNix.determinateNixd.garbageCollector.strategy
= "automatic"` (2026-09-15, `modules/parts/compose.nix`) hands background collection to
determinate-nixd, and `customSettings.auto-optimise-store = true` hard-links duplicates as
paths land. So this step is a **report**, and a hand-run collection is only for "I want the
space back now" — not routine upkeep.

```bash
# host
df -h /nix | tail -1
sudo nix-collect-garbage -d     # only on an explicit ask; the background collector
                                # otherwise handles this, and `-d` drops EVERY old
                                # generation, leaving no rollback target

# nixpi — report only, never collect without an explicit ask (live server)
```

### E2. Determinate Nix version drift (macos)

The Mac's Nix is upgraded by `sudo determinate-nixd upgrade`, NOT by `activate` — the
`determinate` flake input only pins the NixOS hosts' Nix. Nothing else reports the drift
(found 2026-09-21: 3.22.4 running while 3.22.5 was advised). Report it; upgrade only in
`fix` mode:

```bash
determinate-nixd status 2>&1 | grep -m1 -i 'now available' || echo "determinate-nixd: current"
sudo determinate-nixd upgrade     # fix mode only; restarts the daemon (seconds)
```

### E3. launchd units: declared vs loaded, exits, log growth (macos)

`nix flake check` proves what the config **says**. Nothing proved what launchd actually
**did** — which is how `activate-agenix` and both `github-runner-macos-*` daemons sat outside
the system domain for ~21h on 2026-09-22, taking `/run/agenix` and five CI lanes with them,
across four activations that each reported success. Report only; every remedy needs root:

```bash
nix run .#launchd-doctor        # exit 1 = findings; LAUNCHD_DOCTOR_WARN_KB tunes the log threshold
```

Four sections, and they are **not** equally urgent:

| Section | Urgency | Remedy |
|---|---|---|
| `NOT LOADED` | **act now** — a fleet unit is silently absent | `sudo launchctl bootstrap <domain> <plist>`; `modules/darwin/launchd-reconcile.nix` makes the next activation do it |
| `EXIT <n>` | investigate — loaded but failing every spawn | read the unit's log; `exit 78` is the boot/mount race, not a crash |
| log size | routine | long-lived agents are fd-pinned and **not** covered by `system.newsyslog` (see `modules/darwin/logging.nix`) |
| disabled-DB / orphan logs | cosmetic | litter from removed features; delete only when sure the feature is gone |

**Never bootstrap in `fix` mode without asking.** It is under **always confirm**: starting a
daemon the operator deliberately booted out is exactly the wrong move, and
`/etc/nix-darwin/launchd-hold/<label>` is the supported way to keep one down.

### F. Host re-activation

Only if repos touched in this run actually compose macos (i.e. their
`flake.lock`/`flake.nix` changed) or the user asked for it directly:

```bash
# macos — from anywhere. `activate` (packages/activate.nix) self-elevates via
# Touch ID, names the flake dir + branch@rev + (DIRTY) before it builds, and
# warns if /run/current-system has drifted from the system profile.
activate
```

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
- **GC:** host freed X | guest freed Y (or skipped, VM down) | nixpi: N free (report only)
- **Determinate Nix (macos):** current | X.Y.Z advised, running A.B.C — upgraded | report only
- **Hosts:** macos re-activated | skipped (why)
- **Verdict:** CLEAN | FIXED (list what) | NEEDS ATTENTION (why, and what needs a human decision)
```

## Compose with existing automation

```
/fleet-doctor [audit|fix] [scope]   → this skill
/hygiene [scope]                     → nix-config's own LEAN/DRY pass (composed by step D)
/eval                                → nix-config eval only, no cross-repo scope
gh pr list / gh run list             → what this skill's B/C steps wrap
```

A lightweight SessionStart nudge (`.claude/hooks/fleet-doctor-digest.js`)
reminds you to run this when it's been a while — see that file for the
threshold. It never runs checks itself, only reads a local timestamp.
