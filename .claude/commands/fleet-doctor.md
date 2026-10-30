---
description: >
  Fleet-wide consistency sweep — branches/worktrees, open PRs, CI, nix-config's
  own hygiene, Nix store GC, host re-activation — across every repo in the
  fleet manifest. Composes the fleet-doctor skill with nix-hygiene, git-purity
  and pr-title.
argument-hint: "[audit|fix] [repo|host]  # e.g. fix | audit macos"
---

Run the **fleet-doctor** project skill (`.claude/skills/fleet-doctor/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| `audit` | Read-only — report findings, fix nothing |
| `fix` | Audit then apply the skill's auto-fix table (default if omitted) |
| anything else | Scope: a manifest repo name (today only `nix-config` — `nix-personal` was RETIRED 2026-09-15) or a host (`macos`) |

Examples:

- `/fleet-doctor` → fix, full fleet
- `/fleet-doctor audit` → report only, full fleet
- `/fleet-doctor fix macos` → fix scoped to one host (repo sweeps skipped and reported as such)

## Required sequence

1. **Read** `.claude/skills/fleet-doctor/SKILL.md` and follow it (checklist A→F).
2. Read `.claude/skills/fleet-doctor/fleet-repos.txt` for the manifest — do not hardcode a repo list elsewhere.
3. Apply the skill's **fix policy table** exactly — auto-fix only what it lists as auto-fix; everything else is a reported finding, confirmed with the user before acting.
4. If nix-config itself is in scope: compose the **nix-hygiene** skill (same mode) rather than re-deriving its checks.
5. End with the skill's **Fleet-doctor report** block.
6. On completion, update `${XDG_STATE_HOME:-~/.local/state}/nix-config/fleet-doctor-state.json` — per user, not per checkout, so a worktree session does not read "never run" (the reader is `.claude/hooks/fleet-doctor-digest.js`):

   ```bash
   node -e 'const fs=require("fs"),os=require("os"),path=require("path");const f=path.join(process.env.XDG_STATE_HOME||path.join(os.homedir(),".local/state"),"nix-config","fleet-doctor-state.json");fs.mkdirSync(path.dirname(f),{recursive:true});let s={};try{s=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}s.lastRunAt=new Date().toISOString();s.lastMode=process.argv[1]||"fix";fs.writeFileSync(f,JSON.stringify(s,null,2)+"\n")' -- "<audit-or-fix>"
   ```

## Do not

- Merge any PR, ever, regardless of mode — always a reported finding.
- Auto-fix CI failures — diagnosis is repo/workflow-specific; offer to investigate, don't guess.
- Touch nixpi beyond a disk-usage report without an explicit ask.

$ARGUMENTS
