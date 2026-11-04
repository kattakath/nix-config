---
description: >
  Fleet-wide consistency sweep — branches/worktrees, open PRs, CI, nix-config's
  own hygiene, Nix store GC, launchd/terranix drift, heartbeats, nixpi unit
  health and cache warmth, host re-activation — across every repo in the
  fleet manifest. Composes the fleet-doctor skill with nix-hygiene, git-purity
  and pr-title.
argument-hint: "[fix] [repo|host]  # e.g. (nothing) | fix | audit macos"
---

Run the **fleet-doctor** project skill (`.claude/skills/fleet-doctor/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| (nothing) or `audit` | **Default.** Read-only — every `FD-*` rule over the whole manifest, fix nothing |
| `fix` | Audit, then apply the skill's auto-fix table — only when asked |
| anything else | Explicit scope: a manifest repo name (any line of `.claude/skills/fleet-doctor/fleet-repos.txt`) or a host (`macos`). Checks outside it report `skipped:` |

Examples:

- `/fleet-doctor` → audit, full fleet — the same run every time
- `/fleet-doctor fix` → audit, then the auto-fix table
- `/fleet-doctor fix macos` → fix scoped to one host (repo checks report `skipped: scope`)

## Required sequence

1. **Read** `.claude/skills/fleet-doctor/SKILL.md` and follow it (checklist A→F, including E2–E9).
2. `git fetch origin`, record nix-config's `origin/<default>` SHA, and read the manifest
   (`.claude/skills/fleet-doctor/fleet-repos.txt`) and every repo-declared fact (E5's
   `nix eval`, E8's unit list) from that SHA, never from this checkout. Do not hardcode a repo
   list elsewhere.
3. Apply the skill's **fix policy table** exactly — auto-fix only what it lists as auto-fix; everything else is a reported finding, confirmed with the user before acting.
4. If nix-config itself is in scope: compose the **nix-hygiene** skill (same mode) rather than re-deriving its checks.
5. Write the run as health+json from `doctor-report skeleton fleet-doctor <sha>`, one
   `checks` key per `FD-*` rule. `doctor-report validate`, `doctor-report publish fleet-doctor
   <file>`, `doctor-report diff` against the previous `latest`. Then the skill's
   **Fleet-doctor report** block. The verdict is the file's: **0** pass, **2** warn or fail,
   **1** error.
6. On completion, update `${XDG_STATE_HOME:-~/.local/state}/nix-config/fleet-doctor-state.json` — per user, not per checkout, so a worktree session does not read "never run" (the reader is `.claude/hooks/fleet-doctor-digest.js`):

   ```bash
   node -e 'const fs=require("fs"),os=require("os"),path=require("path");const f=path.join(process.env.XDG_STATE_HOME||path.join(os.homedir(),".local/state"),"nix-config","fleet-doctor-state.json");fs.mkdirSync(path.dirname(f),{recursive:true});let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}s.lastRunAt=new Date().toISOString();s.lastMode=process.argv[1]||"audit";fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")' -- "<audit-or-fix>"
   ```

## Do not

- Merge any PR, ever, regardless of mode — always a reported finding.
- Auto-fix CI failures — diagnosis is repo/workflow-specific; offer to investigate, don't guess.
- Touch nixpi beyond its read-only reports (disk usage, step E8's unit status) without an explicit ask.
- Run any `*-apply`, or re-run a workflow, to clear an E6–E9 finding — those steps are report-only.

$ARGUMENTS
