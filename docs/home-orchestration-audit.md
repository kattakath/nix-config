# Pre-Implementation Safety Audit — Home Orchestration Plugin Split (v2 plan)

**Scope:** Read-only audit of whether the v2 plan's HOME / PROJECT / SPLIT classification
(plan §2 table) cleanly separates portable HOME rules from this-repo-specific PROJECT rules
with no cross-contamination. No files changed. Evidence cites real assets under
`~/ismailkattakath/nix-config/.claude/`.

**Overall verdict: QUALIFIED NO** — the *design intent* is sound and the plan already
names the two big transforms (re-mechanize `delegate-team.js`; genericize `stop-gate.js`),
but **two HOME-classified assets ship project poison in their current form** and are not
flagged for transformation in the §2 table (`memory-loader.js` hardest, `superhook-review.md`
second). With those fixed the separation is clean. Counts: **Check 1 = 4 failing/leaky HOME
assets; Check 2 = 3 rules with drift risk (orchestration triple-stated + already conflicting
with v2; PR-consolidation; git-purity); Check 3 = 4 conflict/precedence issues; Check 4 = 3
genuinely ambiguous classifications.**

---

## CHECK 1 — POISON / HIDDEN COUPLING in HOME-classified assets

Scanned every asset the §2 table marks HOME (or the HOME half of a SPLIT) for content that
secretly assumes THIS Nix/CF project.

### 1a. `hooks/delegate-team.js` — **FAILS (known, plan-acknowledged)**
- `delegate-team.js:27` — literal wording "this repo operates orchestrator-first" (repo-specific voice).
- `delegate-team.js:60-62` — enumerates **this project's concrete worker agent types**:
  `platform-compiler` (Nix evaluation), `nix-researcher` (root-cause), `ci-release-driver`
  (push→CI→merge). None exist in an unrelated non-Nix project; a portable policy must describe
  workers **by capability**, not by these names (plan §5 already says this).
- Plan §2 line 48 tags it "re-mechanized — §3, §7" and Phase 2 says rewrite, so the coupling is
  *expected to be stripped*. **Must-do before shipping:** parameterize/remove the three worker-type
  names and the "this repo" voice; do NOT port §16-33's "HARD, STRICT… not authorized to deviate"
  language (it contradicts v2 §7 — see Check 3).

### 1b. `hooks/memory-loader.js` — **FAILS HARD (NOT flagged in the §2 table — biggest leak)**
Classified HOME ("Generic session-context surfacing", §2 line 50) but the content is Nix/project-specific
end-to-end:
- `memory-loader.js:2` — "SessionStart memory loader for the **Nix project**".
- `memory-loader.js:53` — surfaced header hardcodes "the candid 'why' behind this **Nix repo**".
- `memory-loader.js:71,75-76` — instructs the agent to run **`/remember-nix`** (a PROJECT-classified
  command per §2 line 56) and to record "a significant **Nix** decision".
The *mechanism* (echo `memory/INDEX.md`, count `decisions/findings/values`) is portable, but every
string it emits is Nix-branded AND it points at a project-local command. Dropped verbatim into a
non-Nix repo it would tell the user to run a command that doesn't exist and mislabel their memory as
"Nix". **This is a misclassification, not just wording** — see Check 4. Must become SPLIT (home ships
the surfacing mechanism with neutral labels + a configurable command name) or move to PROJECT.

### 1c. `commands/superhook-review.md` — **LEAKY (NOT flagged; classified HOME, §2 line 57)**
- `superhook-review.md:37-38` — hardcodes the event→inner-hook map `Stop -> .claude/hooks/stop-gate.js`
  and `UserPromptSubmit -> .claude/hooks/delegate-team.js`. After the split, `delegate-team.js` is
  removed (Phase 2) and `stop-gate.js` becomes a generic driver — so this HOME command's diagnosis
  table references project script paths that won't exist at those names. It depends on project layout.
- `superhook-review.md:45` — "out of scope per **project policy**" (project-voice).
- Fix: make the event→script mapping data-driven/discovered (read the actual configured hook command)
  rather than a hardcoded Nix-era table; drop "project policy" phrasing.

### 1d. `hooks/superhook.js` — **PORTABLE (trivial nit only)**
- `superhook.js:22` comment cites "e.g. git-purity" as an example block; `.claude/hooks/*` paths are
  computed from `CLAUDE_PROJECT_DIR`. No functional coupling. Optional: strip the git-purity example
  from the comment. Keep HOME.

### 1e. `hooks/superhook-digest.js` — **PORTABLE (clean)**
Generic incident-log reader; the only cross-reference is `/superhook-review` (also HOME). No Nix/CF/host
strings. Keep HOME as-is.

### 1f. `rules/pr-consolidation.md` — **PORTABLE (clean)**
Vendor-neutral git/GitHub workflow (`gh pr list`, `main`, branches). Nothing Nix/CF-specific. Reads
correctly verbatim in any repo. Keep HOME.

**Also flag (plan factual error, feeds Check 2/4):** §2 line 52 claims `~/.claude/CLAUDE.md` holds
"reuse-existing-tools + never-push preferences". The **actual** global `~/.claude/CLAUDE.md` contains
only the tool-prioritization / cognitive-stack tables — the reuse-existing and never-push rules live in
the **auto-memory** (`MEMORY.md` → `feedback_reuse_existing_actions_scripts.md`,
`feedback/never-push-without-explicit-say-so.md`), not CLAUDE.md. The plan mislocates them; the home
plugin can't "migrate" text that isn't where it says.

---

## CHECK 2 — REDUNDANCY / DRIFT RISK

### Orchestration policy — stated in **FOUR** places today, and already self-contradictory vs. v2
1. `hooks/delegate-team.js:26-102` (runtime injection — the current source of truth).
2. `docs/orchestration.md` (whole file; `:3-9` explicitly says it "mirrors delegate-team.js… the hook
   wins if they disagree").
3. `CLAUDE.md` "Orchestration model" section (repo root, ~7 bullets restating the same policy).
4. Planned: home `orchestrator-policy` skill + home `CLAUDE.md` stanza.
- **Drift risk is already real, not hypothetical:** all three *existing* copies state the HARD "manager
  for every substantive task" rule (`delegate-team.js:34-39`, `orchestration.md:60-67`, CLAUDE.md
  "Delegate substantive work"), which **v2 §7 explicitly relaxes**. The moment the skill is written to
  §7, three stale copies contradict it.
- **Recommendation:** single source of truth = the home `orchestrator-policy` **skill** (advisory,
  overridable — plan §3 is right). Then: home `CLAUDE.md` stanza → a 1-2 line **pointer** to the skill,
  not a restatement; project `CLAUDE.md` "Orchestration model" section → delete or shrink to a pointer;
  `docs/orchestration.md` → delete (its whole reason for existing, "mirror the hook", evaporates once the
  hook is gone) or convert to a pointer. Do **not** keep any full restatement of the routing rule in
  more than one place.

### PR-consolidation — stated in TWO places (already a good pattern)
- Full rule: `rules/pr-consolidation.md`. Pointer/summary: repo `CLAUDE.md` (the `.claude/rules/…`
  bullet in the file list). This is the desired shape — one authoritative file + a pointer.
- **Recommendation:** single source = the rule file (moves HOME); the CLAUDE.md mention stays a pointer.
  No drift concern beyond keeping the pointer a pointer.

### git-purity — stated/enforced in FIVE places (PROJECT — correct, but heavily duplicated)
- Prose: `rules/git-purity.md` + repo `CLAUDE.md` "Important Notes" ("Flakes ignore untracked files").
- Mechanical enforcement: `hooks/autostage-nix.js` (PostToolUse stage), `hooks/stop-gate.js:89-101`
  (untracked-`.nix` block), and the `SessionStart` inline hook in `settings.json:100` (untracked-`.nix`
  warning).
- All correctly PROJECT (flake `.nix` semantics). Duplication here is *defensible* (prose rule +
  independent mechanical nets), but note: single prose source of truth = `rules/git-purity.md`; CLAUDE.md
  should stay a pointer. The three enforcers are code, not restatements, so they don't "drift" from the
  rule the way prose copies do.

---

## CHECK 3 — AMBIGUITY / CONFLICT / PRECEDENCE

### 3a. HARD-rule vs. v2 §7 relaxation — **direct contradiction if any old copy survives**
`delegate-team.js:28-33` / `orchestration.md:60-67` / CLAUDE.md assert the policy is a "HARD, STRICT
rule… NOT authorized to deviate/relax," overridable only by an explicit in-the-moment user instruction.
v2 §7 makes the manager **optional** for single-shot work by the agent's own routing judgment (Q1/Q2).
These cannot both be live. **Precedence trap (plan §3, correct):** a hook-injected hard rule can only be
escaped by *disabling the plugin*, never softened by project text — so if nix-config **keeps**
`delegate-team.js` as a hook after adopting the home advisory skill, the **hook wins** and silently
overrides the §7 relaxation. Plan Phase 2 deletes the original; **audit gate: verify no
`delegate-team.js` hook (and no "hard strict" restatement in CLAUDE.md/orchestration.md) survives**, or
the home relaxation is dead on arrival.

### 3b. HOME command depends on PROJECT hook script names
`commands/superhook-review.md:37-38` (HOME) hardcodes `delegate-team.js` / `stop-gate.js` paths. Removing
`delegate-team.js` and genericizing `stop-gate.js` (both project-side transforms) **breaks the home
command's diagnosis mapping**. Separation breaks the home asset unless the mapping is made discovery-based.

### 3c. HOME hook depends on a PROJECT command + project memory
`memory-loader.js` (HOME) tells the agent to run `/remember-nix` (PROJECT) and surfaces `memory/`
(gitignored project store). A HOME asset that instructs use of a PROJECT-only command is a
cross-layer dependency that **breaks when the two are separated** (home plugin enabled in a repo with no
`/remember-nix` command → dangling instruction). Confirms 1b: this is SPLIT/PROJECT, not HOME.

### 3d. Cascade determinism — mostly resolved, two under-specified spots
- The plan's cascade (Managed→CLI→Local→Project→User) resolves **advisory text** deterministically:
  project CLAUDE.md/skill appends/overrides the home layer — good, and it's exactly why §3 says put the
  relaxable policy in a skill not a hook.
- **Under-specified #1 — SPLIT stop-gate no-op:** the home generic gate must cleanly no-op in a non-Nix
  repo (plan open-question already flags this). Today `stop-gate.js:89-101` runs git-purity on `*.nix`
  and `:122-227` shells to `nix`/`devcontainer`/`/workspaces/nix-config`; the generic home half must
  assume none of that and only invoke a **project-declared** command. If the project declares none →
  must silently approve, not block. Not yet specified precisely.
- **Under-specified #2 — two SessionStart hooks:** home `session-rehydrate.js` (§6c) and project
  `memory-loader.js` both fire on SessionStart; their ordering/interaction and whether rehydration output
  is expected before/after memory surfacing is unspecified. Low risk, worth a line in the plan.

---

## CHECK 4 — CLEAN-SEPARATION VERDICT

**Verdict: QUALIFIED NO in the assets' current form; YES achievable after the plan's named transforms
PLUS two reclassifications the §2 table currently gets wrong.**

- The PROJECT set is genuinely this-repo-specific and self-contained (Nix agents, `git-purity.md`,
  `autostage-nix.js`, eval/update-input/remember-nix commands, fleet skills, `nix-declarative` output
  style, Nix CLAUDE.md sections). No leakage *outward* from PROJECT into HOME. Good.
- The HOME set is **not yet** self-contained/portable: it leaks project assumptions in `delegate-team.js`
  (acknowledged), and — **not acknowledged** — in `memory-loader.js` and `superhook-review.md`.

**Genuinely ambiguous classifications (could go either way) + recommendation:**
1. **`hooks/memory-loader.js` — table says HOME; should be SPLIT (lean PROJECT).** Mechanism is portable,
   but 100% of emitted text is Nix-branded and it invokes `/remember-nix`. Recommend: HOME ships a generic
   memory-surfacer that takes project-supplied labels + command name; project supplies "Nix"/`remember-nix`.
   If a shim is overkill, classify PROJECT. **Do not leave it HOME as-is** — biggest single leak.
2. **`commands/superhook-review.md` — table says HOME; is leaky.** Keep HOME only if the event→hook
   mapping (`superhook-review.md:37-38`) and "project policy" wording are genericized/discovery-based;
   otherwise SPLIT. As written it assumes project hook filenames.
3. **`hooks/superhook.js` — table says HOME; agree HOME.** Only a comment example ("git-purity",
   `superhook.js:22`) touches project vocabulary; functionally portable. Strip the example, ship HOME.

**Single most important blocker:** `memory-loader.js` is classified HOME but is Nix-project-coupled in
both its emitted text and its `/remember-nix` dependency — porting it verbatim into an unrelated repo
misbehaves. It (and the un-flagged leak in `superhook-review.md`) must be reclassified/genericized before
implementation, and every stale copy of the pre-§7 "hard manager-for-everything" rule
(`delegate-team.js`, `docs/orchestration.md`, repo `CLAUDE.md`) must be retired in the same pass or the
v2 §7 relaxation is silently overridden.
