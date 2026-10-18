---
description: >
  LEAN/DRY/modular hygiene pass for this nix-config repo — audit, fix, nix fmt,
  flake check. Composes the nix-hygiene skill with existing gates.
argument-hint: "[audit|fix] [scope]  # e.g. audit docs | fix packages/"
---

Run the **nix-hygiene** project skill (`.claude/skills/nix-hygiene/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| `audit` | Findings only — no edits |
| `fix` | Audit then apply safe fixes (default if omitted) |
| anything else | Scope: host name (`macos`, `nixpi`, `nixvm`, `nixos`), path (`packages/`, `docs/`, `.claude/`), or area (`docs`, `claude`) |

Examples:

- `/hygiene` → fix, full repo judgment with focus on dirty/recent surfaces
- `/hygiene audit` → report only
- `/hygiene audit docs` → docs↔flake drift only

## Required sequence

**Ultracode, or the operator asked for a workflow?** Run the saved
[`nix-hygiene-pass`](../workflows/nix-hygiene-pass.js) workflow instead of steps 1–4 (args:
`{scope, recent}`). It fans the checklist out to six auditors, has two skeptics refute each
finding, and keeps ONE fixer so parallel edits never collide in `CLAUDE.md`. Then do step 5
from its result — and treat any dimension it logs as UNAUDITED as not covered. Its fixer is
barred from every **agent-facing** path (`CLAUDE.md`, `claude/`, `.claude/`, policy modules,
`infra/`): those come back as `forHuman`, and YOU apply them here, under the operator's review.

1. **Read** `.claude/skills/nix-hygiene/SKILL.md` and follow it (checklist A→H).
2. **Read** root `CLAUDE.md` conventions if changing module layout or secrets — plus
   `docs/repo-map.md` → `docs/map/` (the eleven-file fleet map) or
   `docs/secrets-and-keychain.md` for the detail
   `CLAUDE.md` intentionally no longer carries.
3. If **fix** mode: apply changes; `git add` `.nix` as you go (git-purity).
4. **Mechanical gate** after any fix:
   - `git add -A`
   - `nix fmt` (then stage again)
   - `nix flake check` — or scoped `nix eval` of affected host toplevels if full check is too heavy; state what you ran
5. End with the skill’s **Hygiene report** block (Mode, Scope, Findings, Gates, Verdict).

## Do not

- Open feature work or drive-by refactors outside findings.
- Skip the mechanical gate after edits.
- Claim both systems passed if only one was evaluated.

$ARGUMENTS
