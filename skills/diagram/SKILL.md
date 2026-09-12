---
name: diagram
description: Render a mermaid diagram as real ASCII boxes in the terminal. Use when I want a rendered diagram of an architecture, flow, or state.
allowed-tools: Bash(printf:*), Bash(mermaid-ascii:*)
---
Author a mermaid diagram for: $ARGUMENTS.
Use graph/flowchart only. Keep it small; split if large.

Render CONDENSED and VERTICAL — always these flags:

    printf 'graph TD\n  A["Start"] --> B["Process"] --> C["End"]\n' | mermaid-ascii -p 0 -x 1 -y 2

- `-p 0` no border padding, `-x 1` minimal horizontal gap, `-y 2` the MINIMUM that still leaves
  an arrow stem (`-y 1` collapses `│▼` to a bare `▼`). The unflagged default wastes ~2x the
  lines and ~3x the width — never ship it.
- **NEVER pass `-a`/`--ascii`** — it means "don't use extended character set" and downgrades the
  box-drawing glyphs (`┌───┐ │ ▼`) to `+---+ | v`. That is plain ASCII, not mermaid-ascii output.
- `graph TD` is the DEFAULT. Use `LR` only for 2-3 nodes; a 4+ node `LR` chain is always too
  wide for a terminal and wraps mid-box into unreadable garbage.
- MEASURE the width before showing it, hard budget <=80 cols — "looks fine" is not a check:

    ... | mermaid-ascii -p 0 -x 1 -y 2 | wc -L      # true display columns

  Use `wc -L`, **not** `awk length()` — awk counts bytes, so each box glyph counts 3 and a
  17-column diagram reports 51. Over 80: shorten labels, switch to `TD`, or split in two.
- Dotted/thick edges (`-.->`, `==>`) do NOT render — mermaid-ascii turns the whole line into a
  literal node label. Use plain `-->` only.
- Every node and edge must be something you VERIFIED. A plausible but unverified diagram is
  worse than no diagram.

Show ONLY the rendered ASCII output in your reply — never the raw mermaid source.
If rendering errors, fix the source and retry until it renders.
