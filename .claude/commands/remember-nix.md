---
description: Capture a Nix-project decision, finding, or value into the gitignored project memory (memory/) for future reference.
argument-hint: "<decision | finding | value | note to remember>"
allowed-tools: Read, Write, Edit, Bash(ls:*)
---

Record something worth remembering about THIS Nix flake / Home-Manager project into the
local, gitignored `memory/` store — the candid "why" behind the repo, distinct from the
committed docs. `$ARGUMENTS` is the thing to remember (a decision, finding, value, or note).

This memory is gitignored on purpose: write candidly, cite real `file:line` evidence, and
don't polish it like public documentation.

## Steps

1. **Classify** what `$ARGUMENTS` is:
   - a **decision** (a choice + its reasoning/tradeoff) → `memory/decisions/`
   - a **finding** (a non-obvious technical fact or gotcha) → `memory/findings/`
   - a **value** (a principle the project holds) → `memory/values/`
   - a **timeline event** (how the project changed) → append to `memory/evolution.md`
   When ambiguous, pick the closest and say which you chose.

2. **Check for an existing file** on the same topic (`ls` the target dir, read candidates).
   If one exists, UPDATE it rather than creating a duplicate. Otherwise create a new
   kebab-case `.md` file.

3. **Write the entry** using the structure already used in that directory (decisions:
   Decision/Reasoning/Evidence/Implications; findings: Finding/Why it matters/Evidence;
   values: Value/How it shows up/Tradeoffs accepted). Include `date: ` in frontmatter
   (today's date) and ground claims in real `file:line` references where possible. Label
   anything you infer rather than observe as "(inferred)".

4. **Update `memory/INDEX.md`** — add or update the one-line pointer for this entry under
   the correct section, matching the existing index format.

5. Confirm to the user what was captured and where. Do NOT `git add` memory/ — it is
   gitignored by design.
