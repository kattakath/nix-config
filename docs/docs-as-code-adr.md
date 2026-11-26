# ADR-014 — Docs as code: facts come from the flake, prose only explains

**Status:** **DECIDED 2026-11-25** (the operator chose "ADR, then nix-config pilot",
click-to-select). The pilot is § 5. Fleet rollout waits for § 6's measurement.

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
occurrence. **69 are documentation drift.** Grouped by what drifted, not by rule:

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
- **Not measured: tokens per audit.** Grafana's `claude_code_token_usage_tokens_total` has
  totals per day, not per skill. § 6 fixes that before any before-and-after claim.

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
| **C** | Restating is a review finding (`NH-C-fact-twice`), fixed by deleting or pointing | `doc-fix-delete-or-point`; DRY (Hunt & Thomas) | rule only |
| **D** | Retired names in a tombstone list; a check fails on a live mention outside history docs | Vale's `existence` rule (Vale 3.27.0 is in nixpkgs) | deferred |
| **E** | Every cited commit SHA must resolve | `git cat-file -e` | deferred |

**Out of scope: an options reference.** ADR-002 § 9.5 measured `nixosOptionsDoc` and held it
back: at `warningsAreErrors = false` it is a gate that cannot fail, and `home-manager.users`
renders as one opaque row. That still holds. A § 7 condition reopens it.

**The recursion trap stays.** A check cannot render the checks set it belongs to, so the
checks inventory is still never generated.

## 5. Pilot order — one commit each, nix-config only

1. This ADR.
2. **A, generalized:** `generatedBlocks` becomes an attrset of `{ doc, render }`.
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
   marked spans. Each run records its Claude Code `session.id` in the SARIF `run.properties`.
   Every `rules.json` key stays, because `doctor-report validate` requires them.

## 6. Acceptance — measured per run, before the fleet rollout

| Metric | Baseline | How |
|---|---|---|
| Doc-drift findings per non-vacuous run | 69 unique over 4 non-vacuous runs ≈ **17 per run** | SARIF, by fingerprint |
| Tokens per `/hygiene` run | **unmeasured** | sum `claude_code_token_usage_tokens_total` by the run's `session.id` |

Roll out fleet-wide (the writer and the check move to the shared `kattakath/.github` gate,
with no per-repo copies) only when two consecutive runs show fewer doc-drift findings and no
rise in tokens.

## 7. Alternatives that lost — and what would reopen them

| Option | Why it lost | Reopen when |
|---|---|---|
| A docs site (mdBook, Docusaurus) | It renders docs; it does not make them true | a reader outside the operator needs a site |
| An AI drift checker in CI | Non-deterministic, and it costs the tokens this ADR cuts | never for facts; maybe for prose, if § 6 shows C stays large |
| jscpd for duplicate paragraphs | Not in nixpkgs. An npm fetch is an unvetted download | it lands in nixpkgs, or a nixpkgs tool covers markdown |
| `nixosOptionsDoc` options reference | ADR-002 § 9.5 (above) | it can fail on a missing description |
| cog, embedme or a similar embedder | A second toolchain beside a flake that already evaluates everything | never, while the flake is the source |

**Weakest assumption.** The shape grouping in § 2 is by reading each finding's message, not
by re-running anything. If many "stale claims" are really data sets in disguise, A and B cover
more than half, and the estimate is low rather than high.
