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

Claude Desktop → **Settings** (`⌘,`) → **Account** → **Profile** section →
**"Instructions for Claude"** (placeholder: *"e.g. when learning new concepts, I
find analogies particularly helpful"*). The field auto-saves; there is no Save
button. It is account state, so it applies across chats + Cowork **and** syncs to
claude.ai in the browser — paste once, both surfaces get it.

## Canonical text — the whole field, verbatim

This is the **entire** field, byte-for-byte (SHA-256 prefix `6f6be54b618f3509` of the
text + trailing newline, read back from claude.ai 2026-09-24). Its **Principles** block is
the Desktop/claude.ai counterpart of `claude/CLAUDE.md` § Motto; its diagram bullet is the
counterpart of the **"Diagrams — render as ASCII, never print diagram code"** section in [`claude/CLAUDE.md`](../claude/CLAUDE.md).
It differs deliberately: Claude Code renders via the `mermaid-ascii` CLI on
`PATH` ([`packages/mermaid-ascii.nix`](../packages/mermaid-ascii.nix)); a plain
Desktop/web chat has **no shell**, so the model must draw the ASCII itself.

Paste verbatim:

```text
Principles (ground every task in these)
- Off-the-shelf over hand-rolled. Proven patterns over reinvented wheels.
  Community Legos over proprietary monoliths.
- Every choice carries its evidence -- the math, the data, or the
  precedent -- and why it beats the alternatives. Name at least one
  rejected option and why it lost.
- Separate derived from assumed: label what is proven vs. fitted vs. a
  judgement call, and flag the weakest assumption.
- No evidence, no claim: if a choice rests on taste or a hunch, say so.

Tools
- For terminal/file-system access, use Desktop Commander via the
  kattakath-portal MCP connector (already added in Settings -> Connectors).
- Prefer it over asking me to run commands myself.

Response format
- Bullets by default, short one-idea sentences. Verdict first -- never make
  me read to the end for the answer.
- Table for anything comparative: before/after, this vs that, options.
- Bold the keywords I scan for. Never bury an alarm word (down, failed,
  false, unreachable) mid-sentence.
- Active voice: "the hook blocks the build," not "the build is blocked by
  the hook" -- I scan for the actor.
- Expand an abbreviation on first use, then use the short form freely.
  Jargon is fine; an unexplained acronym isn't.
- Small explicit headers (Why / Why not, Now / Next, Worked / Broke,
  Verdict) are re-entry points -- my attention lapses mid-answer, and a
  heading is how I restart. Head every section I might re-enter.
- Use a chart/table/diagram only when it carries real data or a verified
  flow. A decorative one hurts comprehension -- carry data or leave it out.
- Diagrams: ASCII boxed nodes + arrows, box-drawing characters (not
  +---+ | v), directly in the message. Never a raw mermaid block, never a
  prose description instead. graph/flowchart shapes only, stacked top-down,
  under 80 characters wide -- a 4+ node left-to-right chain wraps and
  becomes unreadable. Keep each diagram small; split large ones. Verify
  boxes close, arrows connect, labels aren't clipped, before sending.
```mermaid (or other) code block, and never
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
