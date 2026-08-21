---
description: Author or lint a spec-compliant llms.txt (llmstxt.org v2) for a body of written work.
argument-hint: "[path|url] [--lint] [--full]  # e.g. ./docs | ~/brags/impact.md --full | ./llms.txt --lint"
---

Run the **llmstxt** skill (`${CLAUDE_PLUGIN_ROOT}/skills/llmstxt/SKILL.md`) end-to-end. Read
it, and its `reference/spec.md`, before writing anything.

## Arguments

Parse `$ARGUMENTS` loosely:

| Token | Meaning |
|---|---|
| a path or URL | The corpus to index (a docs tree, a repo, a single document, a live site) |
| `--lint` | Lint an existing `llms.txt` only — no authoring |
| `--full` | Also produce the de-facto `llms-full.txt` companion |
| nothing | Ask what the corpus is and where it will be served |

Examples:

- `/llmstxt ./docs` → index the docs tree
- `/llmstxt ./llms.txt --lint` → validate an existing file and report findings
- `/llmstxt ~/notes/impact.md --full` → index one document plus a bundled `llms-full.txt`

## Required sequence

1. **Scope** — establish the corpus and, crucially, **the URLs it will be served at**. Ask if
   it is not obvious; do not invent a base URL.
2. **Triage** — inventory, then cut. Primary material becomes H2 sections, secondary becomes
   `## Optional`. This is an index, not a sitemap.
3. **Write** — H1, blockquote, heading-free detail region, H2 file lists with informative
   notes, links pointing at the `.md` versions of pages.
4. **Companions** — emit or verify the clean markdown pages the links point at. With `--full`,
   also build `llms-full.txt`.
5. **Lint** — `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/llms_txt_lint.py" [--strict] <file>`.
   Zero errors; name every warning you consciously accepted.
6. **Test** — ask a few real questions with only the llms.txt as the starting point, per the
   spec's own guidance, and report what happened.

Everything written here is **published content**: no secrets, private hostnames, internal
URLs, or personal data.
