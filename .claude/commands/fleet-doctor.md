---
description: >
  Fleet-wide consistency sweep — branches/worktrees, open PRs, CI, cross-repo
  flake pins, Nix store GC, host re-activation — across every repo in the
  fleet manifest. Composes the fleet-doctor skill with nix-hygiene, git-purity
  and pr-consolidation.
argument-hint: "[audit|fix] [repo|host]  # e.g. fix | audit nix-personal | fix macvm"
---

Run the **fleet-doctor** project skill (`.claude/skills/fleet-doctor/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| `audit` | Read-only — report findings, fix nothing |
| `fix` | Audit then apply the skill's auto-fix table (default if omitted) |
| anything else | Scope: a manifest repo name (`nix-personal`, `brags`, …) or a host (`macos`, `macvm`) |

Examples:

- `/fleet-doctor` → fix, full fleet
- `/fleet-doctor audit` → report only, full fleet
- `/fleet-doctor fix nix-personal` → fix scoped to one repo
- `/fleet-doctor fix macvm` → GC + re-activate macvm only

## Required sequence

1. **Read** `.claude/skills/fleet-doctor/SKILL.md` and follow it (checklist A→G).
2. Read `.claude/skills/fleet-doctor/fleet-repos.txt` for the manifest — do not hardcode a repo list elsewhere.
3. Apply the skill's **fix policy table** exactly — auto-fix only what it lists as auto-fix; everything else is a reported finding, confirmed with the user before acting.
4. If nix-config itself is in scope: compose the **nix-hygiene** skill (same mode) rather than re-deriving its checks.
5. End with the skill's **Fleet-doctor report** block.
6. On completion, update `.claude/hooks/.fleet-doctor-state.json`:

   ```bash
   node -e 'const f=".claude/hooks/.fleet-doctor-state.json";const fs=require("fs");let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}s.lastRunAt=new Date().toISOString();s.lastMode=process.argv[1]||"fix";fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")' -- "<audit-or-fix>"
   ```

## Do not

- Merge any PR, ever, regardless of mode — always a reported finding.
- Auto-fix CI failures — diagnosis is repo/workflow-specific; offer to investigate, don't guess.
- Touch nixpi beyond a disk-usage report without an explicit ask.
- Retry-loop on an unreachable macvm — report skipped and move on.

$ARGUMENTS
