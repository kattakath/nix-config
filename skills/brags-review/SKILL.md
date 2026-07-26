---
name: brags-review
description: Turn a mined accomplishment (impact.md, produced by the /brag skill) into an approved LinkedIn post. Use when the user says "run brags review", "review my brags", "draft a LinkedIn post from my brags/impact", or wants to convert a tracked accomplishment into a post. Human-in-the-loop: Gate 1 (pick 1-3 impact entries) -> draft ONE post -> fail-closed redaction gate re-scan -> Gate 2 (approve) -> manual paste. NEVER auto-publishes, never calls a social API, never enriches from the web.
---

# Brags — review (curate stage, human-in-the-loop)

You are the **curate** stage of the brag pipeline. The *mine* stage is the off-the-shelf
`/brag` skill (kammradt/brag-skill), which writes accomplishments to `impact.md`. You DRAFT
one LinkedIn post from those entries, but two human gates bracket every irreversible step
and the deterministic redaction gate has the final say on any text you would show. You
NEVER publish, call a social API, open a logged-in site, or enrich from the web — "enrich"
means articulating from the entry's own captured content only.

## Data location

```bash
BRAG_DATA_DIR="${BRAG_DATA_DIR:?set once in nix-config home.nix home.sessionVariables}"   # the kattakath/brags checkout
IMPACT_PATH="$BRAG_DATA_DIR/impact.md"
REDACT="$BRAG_DATA_DIR/engine/redact.py"
```

## Steps

### 1. Load impact.md
- Read `$IMPACT_PATH`. Each entry is a tracked accomplishment (title + what/impact, from `/brag`).
- If `$IMPACT_PATH` is missing or has no entries, tell the user there is nothing to review —
  they should run `/brag impact` (or `/brag <range>` and save deliverables) first — then STOP.

### 2. HUMAN GATE 1 — pick entries (AskUserQuestion)
- Present the impact entries (title + one-line summary) via **AskUserQuestion**, `multiSelect: true`.
- The user picks **1-3** entries. (This is a real decision → it MUST be click-to-select options,
  never a free-form "which ones?" — per the global always-ask-via-options rule.)

### 3. PRODUCE — draft ONE LinkedIn post
- Draft a single post from the chosen entries' own content:
  - consulting-tuned, **first-person**, structured **problem -> what I did -> one lesson**;
  - include a searchable keyword from the entry;
  - **~1300 chars max**; end with a **soft CTA**.
- Write the draft to a temp file, then GATE it through the deterministic, fail-closed redactor:
  ```bash
  python3 "$REDACT" --scan-file <draft-file>   # exits nonzero on any denylist / secret / scanner-error
  ```
  - **Never show a draft that fails the gate.** If it exits nonzero: REVISE (remove the offending
    material) and re-scan, or ABORT. Report only pass/fail + the reason word — never paste raw
    scanner output that might echo the offending text.
  - Fail-closed: if the scanner cannot run for ANY reason, treat the draft as unsafe and do not show it.

### 4. HUMAN GATE 2 — approve (AskUserQuestion)
- Show the CLEAN (gate-passed) draft, then ask via **AskUserQuestion** with options like
  `Approve & save (Recommended)` / `Edit` / `Discard`.
- If they edit, re-run step 3's gate on the edited text before re-showing. Loop until approved or discarded.
- On approval: write the post to `$BRAG_DATA_DIR/linkedin/<slug>.md` (create the dir; slug from the entry title).

### 5. FINISH
- Tell the user to **paste the post manually** into LinkedIn. No API, no Buffer, no browser
  automation, no auto-publish.

## Hard rules
- Two human gates are mandatory; both are AskUserQuestion click-to-select, never free-form.
- Every draft you would display MUST have passed `redact.py --scan-file` first (fail-closed).
- No web/tool enrichment, no social API, no logged-in-site automation, no auto-publish.
- Never echo secrets or client names — not from entries, not from scanner output.
