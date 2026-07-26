# Global Claude Code instructions — Ismail Kattakath

User-level rules that apply in **every** project and session on this machine (placed at
`~/.claude/CLAUDE.md` declaratively by Home Manager — see `modules/shared/home.nix`).
Project-level `CLAUDE.md` and `.claude/rules/*` add project specifics on top of these.

## Decisions & confirmations — ALWAYS click-to-select (strict)

Whenever there is a decision to make or any human-in-the-loop confirmation to obtain,
present it using the **AskUserQuestion** tool as **click-to-select options** — never as a
free-form question the user must type an answer to.

- Each option has a short **title (label)** and a clear **description** of what it means.
- The **recommended option comes first** and its label ends with **"(Recommended)"**.
- Use **multi-select** when more than one option can legitimately apply together.
- This includes plain go/no-go confirmations before outward or irreversible actions —
  offer them as options (e.g. `Proceed (Recommended)` / `Adjust` / `Cancel`), not prose.

Only skip asking when a sensible default lets you proceed on your own; but when you *do*
ask, it must be selectable options. (The tool always offers an "Other" free-text escape,
so nothing is lost by defaulting to options.)

## Reuse over rebuild

Strong preference: **never reinvent the wheel.** Weight reusing an existing off-the-shelf
tool / standard / library / skill / plugin at roughly **2x** over building something
custom. Only go custom when off-the-shelf genuinely cannot fit — and say why.
