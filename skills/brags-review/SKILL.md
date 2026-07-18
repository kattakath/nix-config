---
name: brags-review
description: Review this week's mined "Brags" and turn one into a LinkedIn draft. Use when the user says "run brags review", "review my brags", "process the brag digest", or wants to convert the weekly Brags mining digest into an approved post. Runs Gate 1 (pick 1-3 hints) -> enrich -> one LinkedIn draft (re-scanned by the fail-closed redaction gate) -> Gate 2 (approve) -> manual paste. Never auto-publishes.
---

# Brags — review (global pointer)

This is a thin global entry point. The authoritative, always-current instructions live in the
private Brags repo — read that file and follow it EXACTLY:

    /Users/ismailkattakath/Documents/brags/.claude/skills/brags-review/SKILL.md

That skill owns the whole human-in-the-loop flow:

1. Read the latest digest at `~/Documents/brags/digests/<period>.md` and the referenced
   `~/Documents/brags/ledger/<slug>.md` records.
2. HUMAN GATE 1 — present the READY hints; the user selects 1-3.
3. Enrich only the chosen hints (no web/tool enrichment in the MVP — articulate from the record's
   own sources).
4. Draft ONE consulting-tuned LinkedIn post, then re-scan it through the fail-closed gate
   (`python3 ~/Documents/brags/engine/redact.py --scan-file <draft>`) — never show a draft that fails.
5. HUMAN GATE 2 — the user approves or edits; on approval write `ledger/<slug>/linkedin.md`.
6. Hand the user the final text to PASTE MANUALLY into LinkedIn. No API, no Buffer, no browser
   automation, no auto-publish.

If that file is missing, tell the user the Brags repo isn't set up at `~/Documents/brags` rather than
improvising the flow.
