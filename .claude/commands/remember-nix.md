---
description: Capture a Nix-project decision, finding, or value into the harness's native per-project memory store, with a classify-then-dedupe pass.
argument-hint: "<decision | finding | value | note to remember>"
allowed-tools: Read, Write, Edit, Bash(ls:*)
---

Record something worth remembering about THIS Nix flake / Home-Manager project into the
native per-project memory store. `$ARGUMENTS` is the thing to remember (a decision, finding,
value, or note).

The store lives OUTSIDE the repo, at
`~/.claude/projects/-Users-ismail-Developer-github-com-kattakath-nix-config/memory/`, and its
`MEMORY.md` index is loaded into context automatically at the start of every session — no hook
required. Nothing here is ever committed, so write candidly and cite real `file:line` evidence
rather than polishing it like public documentation.

> This command used to write an in-repo `memory/` tree surfaced by a `memory-loader.js`
> SessionStart hook. That directory never existed, so the hook never emitted a byte while the
> native store quietly accumulated the real entries. Both were retired; the classification and
> dedupe discipline below is the part worth keeping.

## Steps

1. **Classify** what `$ARGUMENTS` is, into the store's own `metadata.type`:
   - **`project`** — ongoing work, goals, or constraints not derivable from the code or git
     history (this absorbs the old "decision" and "timeline event" categories; convert any
     relative date to an absolute one).
   - **`feedback`** — guidance on how to work in this repo, correction or confirmed approach.
     Include the **why**.
   - **`reference`** — a pointer to an external resource (URL, dashboard, ticket).
   - **`user`** — something about the operator themself (role, expertise, preference).

   A **finding** (a non-obvious technical fact or gotcha) is usually `project`; if it is really
   "do it this way from now on", it is `feedback`. When ambiguous, pick the closest and say
   which you chose.

2. **Check for an existing entry on the same topic** before writing: read `MEMORY.md`, then
   `ls` the memory directory and read any candidate whose slug is close. UPDATE that file
   rather than creating a near-duplicate. Delete an entry that has turned out to be wrong.

3. **Skip what does not belong here.** If the repo already records it — code structure, a past
   fix, git history, `CLAUDE.md`, `docs/repo-map.md` — do not duplicate it into memory. If the
   operator asks to remember one of those anyway, ask what was *non-obvious* about it and store
   that instead.

4. **Write one fact per file**, kebab-case slug, with the store's frontmatter:

   ```markdown
   ---
   name: <short-kebab-case-slug>
   description: <one-line summary, used to decide relevance during recall>
   metadata:
     type: project
   ---

   <the fact. For feedback/project, follow with **Why:** and **How to apply:** lines.>
   ```

   Ground every claim in a real `file:line` reference where possible, and label anything
   inferred rather than observed as "(inferred)". Link related entries with `[[their-slug]]` —
   liberally; a link to an entry that does not exist yet marks something worth writing later.

5. **Add the one-line pointer to `MEMORY.md`**: `- [Title](file.md) — hook`. One line per
   memory, never the content itself.

6. Confirm what was captured, where, and under which type.
