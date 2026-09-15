# Claude Desktop / claude.ai — custom instructions (manual, account-level)

The one piece of Claude Desktop state this repo **cannot** manage declaratively. (Its MCP
servers it now can — see [`claude-desktop-mcp.md`](claude-desktop-mcp.md).)

`~/.claude/CLAUDE.md` (Claude Code's global instructions) is placed by Home
Manager from [`claude/CLAUDE.md`](../claude/CLAUDE.md). **Claude Desktop and
claude.ai do not read that file.** Their persistent instructions live in a
server-side, account-level field — not a local file, not a nix option — so a
machine reset (or a new device signed into the same account) keeps them, but a
*new account* starts blank. This note is the reproducible source of that text so
it can be re-pasted deterministically.

## Where it goes

Claude Desktop → **Settings** (`⌘,`) → **General** → **Profile** section →
**"Instructions for Claude"** (placeholder: *"e.g. when learning new concepts, I
find analogies particularly helpful"*). The field auto-saves; there is no Save
button. It is account state, so it applies across chats + Cowork **and** syncs to
claude.ai in the browser — paste once, both surfaces get it.

## Canonical text — diagrams as ASCII

This is the Desktop/claude.ai counterpart of the **"Diagrams — render as ASCII,
never print diagram code"** section in [`claude/CLAUDE.md`](../claude/CLAUDE.md).
It differs deliberately: Claude Code renders via the `mermaid-ascii` CLI on
`PATH` ([`packages/mermaid-ascii.nix`](../packages/mermaid-ascii.nix)); a plain
Desktop/web chat has **no shell**, so the model must draw the ASCII itself.

Paste verbatim:

```text
Write for a reader who scans and cannot parse thick paragraphs: an answer
that buries the point in prose is a failed answer however correct it is.
Default to bullets and short one-idea sentences, verdict first, a table for
anything comparative (before/after, this vs that, options). Bold the
keywords; never bury an alarm word mid-sentence. Use active voice: "the
hook blocks the build", not "the build is blocked by the hook" - because
the passive buries the actor I am scanning for. Expand an abbreviation on
its first use, then use the short form freely; jargon is welcome, an
unexplained acronym is not.

Small explicit headers (Why / Why not, Now / Next, Worked / Broke, Verdict)
are re-entry points, not just scan anchors: my attention lapses mid-answer,
and a heading is how I restart from the last thing I remember instead of
re-reading from the top. Head every section I might have to re-enter.

Never add a chart, table or diagram just because an answer feels too
textual. A visual that carries real data or a real verified flow helps; a
decorative one measurably hurts comprehension. Carry data, or leave it out.

When a diagram would help explain something (architecture, flow, state,
dependencies), draw it as an ASCII diagram and show the diagram itself:
boxed nodes with arrows, laid out directly in the message. Box-drawing
characters are preferred over +---+ | v.
Never leave a diagram as a raw ```mermaid (or other) code block, and never
just describe it in prose. Use graph/flowchart shapes only. Stack nodes
TOP-DOWN by default and keep every diagram under 80 characters wide -
a left-to-right chain of 4+ boxes is too wide, wraps mid-box, and becomes
unreadable. Keep each diagram small and split a large one into several.
Make sure boxes are closed, arrows connect, and labels aren't clipped
before sending.
```

**Keep this block 7-bit ASCII.** It reaches the field through the macOS clipboard, and
`pbcopy` encodes using the caller's locale — in a `LANG`-less shell (every non-interactive
hook, script and agent session on this Mac) it reads UTF-8 bytes as **MacRoman**, so an em
dash lands in the field as `‚Äî`. Verified 2026-09-15. Belt and braces when re-copying:

```bash
LC_ALL=en_US.UTF-8 pbcopy < file
```

Note: Desktop renders Mermaid natively, so this ASCII rule is a deliberate
choice for **cross-surface parity** with Claude Code, at the cost of Desktop's
nicer visual Mermaid. To instead let Desktop render real diagrams, replace the
"Never leave a diagram as a raw code block" line with an instruction to *output a
`mermaid` code block, which Desktop renders visually.*

## After a machine reset

Restoring `macos` (see [`new-mac-runbook.md`](new-mac-runbook.md))
brings back Claude Code's `CLAUDE.md` automatically. The Desktop field is **not**
part of that — after signing Claude Desktop back into the account, confirm the
text above is present under Profile → Instructions for Claude, and re-paste from
this note if the account was new or the field was cleared.
