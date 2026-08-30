# Claude Desktop / claude.ai — custom instructions (manual, account-level)

The one piece of Claude behaviour this repo **cannot** manage declaratively.

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
anything comparative (before/after, this vs that, options), and small
explicit headers (Why / Why not, Now / Next) as scan anchors. Bold the
keywords; never bury an alarm word mid-sentence.

When a diagram would help explain something (architecture, flow, state,
dependencies), draw it as an ASCII diagram and show the diagram itself —
boxed nodes with arrows, laid out directly in the message. Box-drawing
characters are preferred over +---+ | v.
Never leave a diagram as a raw ```mermaid (or other) code block, and never
just describe it in prose. Use graph/flowchart shapes only. Stack nodes
TOP-DOWN by default and keep every diagram under 80 characters wide —
a left-to-right chain of 4+ boxes is too wide, wraps mid-box, and becomes
unreadable. Keep each diagram small and split a large one into several.
Make sure boxes are closed, arrows connect, and labels aren't clipped
before sending.
```

Note: Desktop renders Mermaid natively, so this ASCII rule is a deliberate
choice for **cross-surface parity** with Claude Code, at the cost of Desktop's
nicer visual Mermaid. To instead let Desktop render real diagrams, replace the
"Never leave a diagram as a raw code block" line with an instruction to *output a
`mermaid` code block, which Desktop renders visually.*

## After a machine reset

Restoring `macos` (see [`mac-key-recovery-runbook.md`](mac-key-recovery-runbook.md))
brings back Claude Code's `CLAUDE.md` automatically. The Desktop field is **not**
part of that — after signing Claude Desktop back into the account, confirm the
text above is present under Profile → Instructions for Claude, and re-paste from
this note if the account was new or the field was cleared.
