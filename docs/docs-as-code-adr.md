# ADR-014 — Docs as code: facts come from the flake, prose only explains

**Status:** **DECIDED 2026-11-25** (the operator chose "ADR, then nix-config pilot",
click-to-select). **Pilot SHIPPED 2026-11-25** (§ 5, all five steps). It differs from the
option as offered: the findings in § 2 pointed at data sets and copied values, not at
`CLAUDE.md`'s command and skill lists, so those lists were not generated. Fleet rollout
waits for § 6's measurement.

**Question.** Most `/hygiene` findings are documentation drift, and every audit re-reads all
the prose to find it. Can docs, diagrams, comments and agent prompts be generated or checked
like code, so drift becomes impossible instead of found?

## 1. Verdict

- **Half of it, yes.** About half of the measured drift is a fact that already lives in the
  flake and was retyped into prose. Generate that half and gate it. It then costs zero tokens.
- **The other half is judgment.** A stale "why" cannot be generated. The cheapest fix is
  **less prose**: point at the fact instead of restating it.
- **Extend, don't add.** ADR-012 § 5 step 5 already shipped the pattern (a marked block,
  `hosts-documented` and `docs-generate`). This ADR makes it N named blocks with one writer
  and one check. It does not add a second mechanism.

## 2. Evidence (measured 2026-11-25)

The last 12 hygiene SARIF runs hold **77 unique findings**, counted by fingerprint, not by
occurrence. Eight runs (2026-11-18) were clean, every rule `pass`, not vacuous; the four
since found 14, 29, 17 and 17. **Doc drift** is a fixed rule list: `NH-C-fact-twice`,
`NH-A-map-drift`, `NH-A-app-undocumented`, `NH-A-runbook-dead-ref` and every `NH-D-*`.
**69 of the 77** carry one of them. `NH-C-fact-twice` also counts code duplicates (the
keychain parser, the run.app formula), so the doc-only share is a little lower. Grouped by
what drifted, not by rule:

| Shape of the drift | Examples from the findings | Mechanism (§ 4) |
|---|---|---|
| Prose lists a data set | the stacks list missed `cf-ai-search`; "the portal holds only Google's servers"; the consumers of a binding | **A.** Generated inventory |
| A literal value copied out of its binding | the CI App id written ~10 times; the runner count; a heartbeat cadence | **B.** Value once |
| A paragraph restated in another file | the Motto quoted twice; a blockquote in two docs; the launchd exception three times | **C.** Pointer discipline |
| A claim about something since retired | the weekly Desktop task; the tor-browser alpha overlay | **D.** Tombstones (deferred) |
| A commit SHA the history rewrite destroyed | `entry-points.md` citing dead SHAs | **E.** SHA resolves (deferred) |

- **Hotspots by file:** `CLAUDE.md` 8, then `docs/map/{infra,engine}.md` 4 each, then
  `docs/map/claude-code.md` and `docs/repo-map.md` 3 each. The rest is spread thin, a third of
  it in `.nix` comments.
- **Volume:** about **1.39 MB** of markdown in `CLAUDE.md`, `claude/`, `.claude/` and `docs/`.
  Over 30 days, 765 `.md` file-touches against 982 `.nix`.
- **Tokens:** `claude_code_token_usage_tokens_total` carries `skill_name`. Over the 10 days to
  2026-11-25, `hygiene` was the costliest skill at **128.6M tokens** (93% cache reads), and
  `fleet-doctor` used 54.0M.

## 3. The contract

1. **A fact has one home, and it is code** — a Nix binding, a `readDir`, a flake output.
2. **Prose may point at a fact or explain why.** It never restates the fact. It never carries
   a count of anything the code can count.
3. **A generated span is marked**, `<!-- BEGIN GENERATED: <name> … -->` … `<!-- END GENERATED:
   <name> -->`. One check proves every span equals its render. One app (`docs-generate`)
   rewrites them.
4. **Audits skip marked spans** (amends ADR-013 § 4). CI already proves them, so an LLM
   re-reading them is the waste this ADR exists to cut. The span markers are that contract.
5. **Renders never depend on the evaluating system.** They read flake-level data and
   `readDir` only, so the darwin and linux gates agree.

## 4. Mechanisms

| | Mechanism | Off-the-shelf it rests on | Pilot? |
|---|---|---|---|
| **A** | Generated inventories, N named blocks | the existing `generatedBlock` (ADR-012); Diagrams-as-Code for any diagram built from the same data | **yes** |
| **B** | A declared literal (e.g. `fleetAppId`) may appear only in its binding; the check greps the tracked tree | a grep in a `runCommand`, like `line-refs-cite-constructs` | **yes** |
| **C** | A paragraph in one live doc that near-copies one in another fails (`docs-near-duplicates`) | jscpd's method (shingles); `doc-fix-delete-or-point` | **shipped** |
| **D** | Retired names in a tombstone list | Vale's `existence` rule | **rejected on data** (§ 7) |
| **E** | Every cited commit SHA must resolve (`nix run .#docs-shas-resolve`, in CI's gitleaks job) | `git cat-file -e` | **shipped** |

**Out of scope: an options reference.** ADR-002 § 9.5 measured `nixosOptionsDoc` and held it
back: at `warningsAreErrors = false` it is a gate that cannot fail, and `home-manager.users`
renders as one opaque row. That still holds. A § 7 condition reopens it.

**The recursion trap stays.** A check cannot render the checks set it belongs to, so the
checks inventory is still never generated.

## 5. Pilot order — one commit each, nix-config only

1. This ADR.
2. **A, generalized — SHIPPED:** `generatedBlocks` is an attrset of `{ doc, lines }`; the
   markers and `render` derive from the name.
   `hosts-documented` checks every span, and `docs-generate` rewrites every span. The
   existing `flake-outputs` block is the first entry, and its render does not change.
3. **A, the stacks — SHIPPED as a row-set gate, not a generated table.** `infra.md`'s stack
   table carries prose columns (state, credential, blast radius) that are judgment, and the
   file sat 88 bytes under its budget. So `infra-stacks-documented` gates the table's ROWS
   against `modules/_lib/terranix-stacks.nix`, both ways, and the prose stays hand-written.
   `CLAUDE.md`'s `infra/` row now points at it instead of listing stacks, which saved 268 bytes.
   A row-set gate is the lighter form of A: use it wherever a hand table has prose columns.
4. **B — SHIPPED:** `values-once`, first entry `fleetAppId` (the most-copied literal). An entry
   reads its value from the evaluated config, never from a second literal. Add one entry per
   binding that hygiene finds copied.
5. **Audit wiring — SHIPPED:** `nix-hygiene` (the skill and the `nix-hygiene-pass` workflow) skips
   marked spans, and only those. Each run records its start and end in the SARIF
   `invocations`, which bounds its token window (§ 6).
   Every `rules.json` key stays, because `doctor-report validate` requires them.

6. **C and E — SHIPPED** (the operator chose to build the deferred three; D failed its
   noise probe). `docs-near-duplicates` covers the live docs only: 6-word shingles,
   Jaccard 0.5. The whole-repo scan found 8 pairs, all outside that scope (capsule README
   boilerplate, one retired doc), and 0 inside it. `docs-shas-resolve` found 19 of 27
   cited SHAs dead from the 2026-11-13 history rewrite. 8 were remapped by UTC author
   date plus subject and rewritten. 11 could not be, and they sit on a void list that
   only shrinks.

## 6. Acceptance — measured per run, before the fleet rollout

| Metric | Baseline | How |
|---|---|---|
| Doc-drift findings per full run (§ 2's rule list) | 14 / 29 / 17 / 17 in the four runs since 2026-11-19 | SARIF, by fingerprint |
| Tokens per `/hygiene` run | 128.6M over the 10 days to 2026-11-25 (no per-run figure yet) | `increase(claude_code_token_usage_tokens_total{skill_name="hygiene"})` over the run's `invocations` window |

Roll out fleet-wide (the writer and the check move to the shared `kattakath/.github` gate,
with no per-repo copies) only when two consecutive runs show fewer doc-drift findings and no
rise in tokens.

## 7. Alternatives that lost — and what would reopen them

| Option | Why it lost | Reopen when |
|---|---|---|
| A docs site (mdBook, Docusaurus) | It renders docs; it does not make them true | a reader outside the operator needs a site |
| An AI drift checker in CI | Non-deterministic, and it costs the tokens this ADR cuts | never for facts; maybe for prose, if § 6 shows C stays large |
| jscpd for duplicate paragraphs | Not in nixpkgs, and an npm fetch is an unvetted download. PMD CPD (7.28.0, in nixpkgs) has no markdown language | it lands in nixpkgs; then `scripts/near-duplicates.py` retires |
| D, a retired-names list (Vale `existence`) | Measured: most mentions of a retired name are correct history. `mcp-public` 127 mentions, 86 with no retirement word on the line; `doctor-report weekly` is still a live subcommand | a tombstone that never appears in history docs |
| `nixosOptionsDoc` options reference | ADR-002 § 9.5 (above) | it can fail on a missing description |
| cog, embedme or a similar embedder | A second toolchain beside a flake that already evaluates everything | never, while the flake is the source |

**Weakest assumptions.** First, `skill_name` may not cover a skill's subagents, so a
fan-out run could read cheaper than it is; check one run's window against the day's total.
Second, the shape grouping in § 2 is by reading each finding's message, not
by re-running anything. If many "stale claims" are really data sets in disguise, A and B cover
more than half, and the estimate is low rather than high.
