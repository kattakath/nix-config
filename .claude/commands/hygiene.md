---
description: >
  LEAN/DRY/modular hygiene pass for this nix-config repo — audits origin/main by
  default (SARIF out), fixes only on `fix`. Composes the nix-hygiene skill with
  existing gates.
argument-hint: "[fix] [scope]  # e.g. (nothing) | fix | audit docs/"
---

Run the **nix-hygiene** project skill (`.claude/skills/nix-hygiene/SKILL.md`) end-to-end.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| (nothing) or `audit` | **Default.** Findings only, no edits, the whole repo at `origin/<default>` |
| `fix` | Audit, then apply safe fixes on a branch off `origin/<default>` — only when asked |
| anything else | Explicit scope: host name (`macos`, `nixpi`, `nixvm`, `nixos`), path (`packages/`, `docs/`, `.claude/`), or area (`docs`, `claude`). Rules outside it report vacuous |

Examples:

- `/hygiene` → audit, every `NH-*` rule, subject `origin/main` — the same run every time
- `/hygiene fix` → audit, then fix
- `/hygiene audit docs/` → docs only (exits 2: the other rules are vacuous)

## Required sequence

**Ultracode, or the operator asked for a workflow?** Run the saved
[`nix-hygiene-pass`](../workflows/nix-hygiene-pass.js) workflow instead of steps 1–4 (args:
`{mode, root, scope, recent}`; `root` is the snapshot, `mode` defaults to `audit`, which skips the
Fix phase). It fans the checklist out to six auditors, has two skeptics refute each
finding, and keeps ONE fixer so parallel edits never collide in `CLAUDE.md`. Then do step 5
from its result — and treat any dimension it logs as UNAUDITED as not covered. Its fixer
edits only its allowlisted roots (`docs/`, `modules/`, `packages/`, `hosts/`, `templates/`,
`sites/`, a root `*.md`) and never an **agent-facing** path (`CLAUDE.md`, `AGENTS.md`,
`claude/`, `.claude/`, `infra/`, any hooks/workflows/settings/mcp/guardrail segment — the
workflow's `AGENT_FACING` predicate is the list): those come back as `forHuman`, and YOU apply
them here, under the operator's review.

1. **Read** `.claude/skills/nix-hygiene/SKILL.md` and follow it (checklist A→H). First its
   § Subject, rules and output: `git fetch origin`, record the SHA, audit a detached snapshot
   of `origin/<default>` — never the checkout this session happens to be on.
2. **Read** root `CLAUDE.md` conventions if changing module layout or secrets — plus
   `docs/repo-map.md` → `docs/map/` (the eleven-file fleet map) or
   `docs/secrets-and-keychain.md` for the detail
   `CLAUDE.md` intentionally no longer carries.
3. If **fix** mode: apply changes; `git add` `.nix` as you go (git-purity).
4. **Mechanical gate** after any fix:
   - `git add -A`
   - `nix fmt` (then stage again)
   - `nix flake check --all-systems --no-build` (both systems — a bare check on the Mac omits aarch64-linux), then
     `nix flake check` (THE suite) — or scoped `nix eval` of affected host toplevels if the full check is too heavy; state what you ran
5. Write the run as SARIF from `doctor-report skeleton hygiene <sha>`, one result per
   `NH-*` rule. `doctor-report validate`, then `doctor-report publish hygiene <file>`, then
   `doctor-report diff` against the previous `latest`. A file that does not validate is a
   failed run (exit 1), not a report.
6. End with the skill’s **Hygiene report** block. The session's verdict is the file's:
   **0** clean, **2** findings or vacuous, **1** error.

## Do not

- Open feature work or drive-by refactors outside findings.
- Skip the mechanical gate after edits.
- Claim both systems passed if only one was evaluated.

$ARGUMENTS
