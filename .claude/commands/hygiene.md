---
description: >
  LEAN/DRY/modular hygiene pass for this nix-config repo — audit, fix, nix fmt,
  flake check. Composes the nix-hygiene skill with existing gates.
argument-hint: "[audit|fix] [scope]  # e.g. fix macvm | audit docs | fix packages/"
---

Run the **nix-hygiene** project skill (`.claude/skills/nix-hygiene/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| `audit` | Findings only — no edits |
| `fix` | Audit then apply safe fixes (default if omitted) |
| anything else | Scope: host name (`macos`, `macvm`, `nixpi`, `nixvm`), path (`packages/`, `docs/`, `.claude/`), or area (`macvm`, `docs`, `claude`) |

Examples:

- `/hygiene` → fix, full repo judgment with focus on dirty/recent surfaces
- `/hygiene audit` → report only
- `/hygiene fix macvm` → fix scoped to macvm/UTM/Screengrab-related tree
- `/hygiene audit docs` → docs↔flake drift only

## Required sequence

1. **Read** `.claude/skills/nix-hygiene/SKILL.md` and follow it (checklist A→H).
2. **Read** root `CLAUDE.md` conventions if changing module layout or secrets.
3. If **fix** mode: apply changes; `git add` `.nix` as you go (git-purity).
4. **Mechanical gate** after any fix:
   - `git add -A`
   - `nix fmt` (then stage again)
   - `nix flake check` — or scoped `nix eval` of affected host toplevels if full check is too heavy; state what you ran
5. If scope touched macvm/UTM: `nix run .#macvm-utm-doctor` when the host can reach the guest (non-fatal if VM down — note skipped).
6. End with the skill’s **Hygiene report** block (Mode, Scope, Findings, Gates, Verdict).

## Do not

- Open feature work or drive-by refactors outside findings.
- Skip the mechanical gate after edits.
- Claim both systems passed if only one was evaluated.

$ARGUMENTS
