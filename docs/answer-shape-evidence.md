# Answer shape — the evidence behind the rules

The **§ Answer shape** rules in [`claude/CLAUDE.md`](../claude/CLAUDE.md) and the
[Brain Signals output style](https://github.com/kattakath/skills/blob/main/plugins/brain-signals/output-styles/brain-signals.md) read like a
formatting preference. They are not. This note records the published standards and the
measured effect sizes behind each rule, so the rules stop being re-litigated as taste — and
so the **one rule that contradicts intuition** (see § The visual trap) survives contact with
the next agent that wants to "add a chart".

Researched 2026-09-15.

## Verdict

**No ADHD-specific formatting standard exists.** The current state of the art is a 2025
INTERACT paper titled *"**Towards** Inclusive Guidelines for Web Design for Adults with
ADHD"* — the "Towards" is the finding.

**Four published standards converge on the rules anyway.** The rules here were arrived at
independently; the literature ratifies them.

## The standards

| Standard | Status | Covers ADHD? | What it mandates |
|---|---|---|---|
| [W3C COGA — *Making Content Usable*](https://www.w3.org/TR/coga-usable/) | W3C Group Note — **supplemental, non-normative** | **Yes, by name** | Headings + [chunking](https://www.w3.org/WAI/WCAG2/supplemental/patterns/o2p05-chunked-media/), explicitly citing ADHD |
| [BDA Dyslexia Style Guide 2023](https://cdn.bdadyslexia.org.uk/uploads/documents/Advice/style-guide/BDA-Style-Guide-2023.pdf) | Trade-body style guide | Dyslexia only | Bullets over continuous prose, concise, **active voice**, headings, **expand abbreviations on first use** |
| [ISO 24495-1:2023 Plain language](https://www.iso.org/standard/78907.html) | **Real ISO standard** (25 countries, 19 languages) | General | Four principles; the first is **Findable** — clear titles, section headings, layout |
| [WCAG 2.2](https://www.w3.org/TR/WCAG22/) | The normative/legal accessibility standard | **Barely** | Cognitive access is thin — which is *why* COGA exists as a bolt-on |

**The trap worth knowing:** WCAG is the standard everyone audits against, and it is the one
that does **not** cover this. No compliance checkbox anywhere produces scannable output.

## The measured effect sizes

| Rule here | Finding | Effect | Source |
|---|---|---|---|
| Bullets, tables, verdict-first | Concise **+58%**, scannable **+47%**, objective **+27%** | **+124% combined** | [Morkes & Nielsen](https://www.nngroup.com/articles/concise-scannable-and-objective-how-to-write-for-the-web/) |
| Same, applied to real production pages | Rewritten Sun.com pages | **+159%** | ibid. |
| **Bold the keywords** | Signaling principle (cues that expose structure) | g = 0.38 | [Mayer meta-analysis](https://www.sciencedirect.com/science/article/pii/S1747938X25000673) |
| **Details in layers**, not one wall | Segmenting principle | g = 0.32–0.36 | ibid. |
| **Diagrams must carry the flow** | Coherence principle / seductive details | **g = −0.37 to −0.41 — negative** | ibid. |

## The visual trap

**"Add a visualization" is not an automatic improvement.** The coherence principle is one of
the best-replicated results in the field — older reviews report it upheld in **23 of 23**
experimental tests (median d = 0.86), and modern meta-analyses put decorative graphics at
**g ≈ −0.4**, i.e. measurably *worse* than no graphic at all.

- A chart that carries data: **helps.**
- A diagram that carries the actual, verified flow: **helps.**
- A diagram added because the answer felt too textual: **hurts, and is measurable.**

This is the evidence for the existing rule in
[`claude/CLAUDE.md`](../claude/CLAUDE.md) § Diagrams — *"the diagram must carry the actual
flow, not decorate the answer"*. Keep it.

## Headings are re-entry points, not scan anchors

COGA's stated rationale for headings is **not** scanning. It is **resumption**:

> a distracted reader loses their place, and headings let them restart from the last point
> they remember — rather than re-reading from the top.

That reframing is why the rule now says *head every section a distracted reader might have to
re-enter*, which is a stricter test than "head the sections worth scanning to".

## Rejected — popular, no evidence

**Bionic Reading** (bolding the first few letters of every word) is the best-known
"ADHD reading aid" and it **does not work**:

| Measure | Result |
|---|---|
| Reading speed (n = 2,074) | **2.6 wpm slower** than plain text |
| Comprehension | **5–8 percentage points worse** |
| Eye-tracking (fixation count/duration) | No significant change |

Source: [*No, Bionic Reading does not work*](https://www.sciencedirect.com/science/article/pii/S0001691824001811).
Do not adopt it, and do not let a downstream tool inject it.

## Deliberately NOT adopted

| Guidance | From | Why not |
|---|---|---|
| Reading-level ceilings, "everyday words only" | ISO 24495-1, BDA | Conflicts with the peer-principal-engineer calibration in [`claude/rules/brain-signals-context.md`](../claude/rules/brain-signals-context.md). Jargon is wanted; **unexplained** jargon is not — hence the first-use-expansion rule instead. |
| Sans-serif fonts, 1.5 line spacing, off-white background, left-align | BDA | Typography, not authorship. The terminal palette owns this — see [`terminal-theme.md`](terminal-theme.md). |
| Autoplay/motion control, progress indicators, auto-save | COGA, ADHD web-design literature | UI affordances; no text-answer equivalent. |

## Where the rules live

| Surface | Wired how |
|---|---|
| Claude Code (all projects) | [`claude/CLAUDE.md`](../claude/CLAUDE.md) § Answer shape → `~/.claude/CLAUDE.md`, placed by Home Manager |
| Claude Code (output style) | [`plugins/brain-signals/output-styles/brain-signals.md` (kattakath/skills)](https://github.com/kattakath/skills/blob/main/plugins/brain-signals/output-styles/brain-signals.md) via `modules/shared/claude-brain.nix` |
| Claude Desktop / claude.ai | **Manual account-level paste** — canonical text in [`claude-desktop-instructions.md`](claude-desktop-instructions.md). This is the drift surface: nothing verifies it is current. |
