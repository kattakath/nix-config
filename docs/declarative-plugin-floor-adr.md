# ADR-008 — A declarative plugin floor: `enabledPlugins` in VCS, ad-hoc on top

**Status:** **Partially accepted, 2026-10-02.** The `declared` lane of §6 is **IMPLEMENTED**
(`local.claudePlugins.declared`); the `assured` lane is **still proposed and unmeasured**. The
document was written to be approved before any Nix, at the operator's instruction, and §9a
records which of §7's open questions the implemented half had to answer and which it sidesteps
by not touching managed settings at all.

**Supersedes nothing.** It extends the boundary #648 drew, and it does **not** revisit
#648's decision (see §3) — that decision is upheld here, not overturned.

---

## 1. The question

> Can the fleet declare, in version control, that a given Claude Code plugin is **enabled**
> or **disabled** — restored on every activation — while the operator's own ad-hoc plugin
> choices keep surviving activations without being persisted?

Today the answer is **no, for all but three plugin names**. §2 establishes that by
measurement rather than by reading the option docs.

## 2. What the fleet can express today — measured, not assumed

`modules/shared/claude-plugins.nix` consumes `cfg.marketplaces.<name>.plugins` in exactly
two places:

```
idsOf / allIds ─┬─> alwaysOnIds ─> programs.claude-code.settings.enabledPlugins
                │                   filtered to THREE hardcoded names (:70-75, :289)
                └─> the per-always-on-name assertion (:186)
```

`extraKnownMarketplaces` (:242) reads only `source` and `autoUpdate`. **It never reads
`plugins`.** So for any name outside `alwaysOnNames` — `claude-code-nix`, `superhook`,
`brain-signals` — a `plugins` entry registers nothing, enables nothing, and gates nothing.
It is a declared catalogue and a comment.

This was not a latent suspicion; it was **demonstrated by a live failure**. PR #751 added
`"empire"` to that list with a comment block asserting the plugin's `settings.agent` would
make the Queen the main agent of every session. It merged. Nothing happened. Measured on
`~/.claude/settings.json` immediately afterwards:

| Source of an `enabledPlugins` id | Count |
|---|---|
| Written by Nix (the always-on three) | **3** |
| The operator's own, ad-hoc | **39** |
| …of which explicitly `false` | **9** (`claude-security`, `llmstxt`, `grok-build`, `resend`, `jsonresume-tailor`, …) |
| `empire@kattakath` | **absent** |

Two facts fall out of that table, and they are the whole case for this ADR:

1. **The operator layer already uses `false`.** Nix can emit only `true`, and only for three
   names. The expressive gap is not hypothetical — it is nine live entries wide.
2. **Nix writes 7% of the effective policy.** The remaining 93% exists only on this one Mac.
   A reflashed or second machine reproduces three plugins and loses thirty-nine.

#751 was reverted in #754 rather than widened, because the defect was a comment claiming a
behaviour that cannot happen — worse than no comment, since the next reader believes it.

## 3. What #648 decided, and why this does not reopen it

`enabledPlugins` used to be `lib.genAttrs allIds (_: true)` — every plugin in every declared
marketplace, force-enabled. #648 narrowed it to three on a specific complaint: **a rebuild
reverted whatever the operator chose in `/plugin`**, which made the UI toggle a lie.

That decision is correct and is upheld here. The membership rule it set —
*"what this repo structurally BREAKS without"* — is also upheld: `empire` does not qualify,
nothing in the repo breaks without it, and widening that list to carry ordinary preferences
would re-create exactly the non-durable toggle #648 removed.

**The gap #648 left is a different one.** It answered *"which plugins must Nix force?"* with
"as few as possible". It never answered *"how does the operator record a deliberate,
reproducible choice that is not load-bearing?"* The answer today is: they can't — the choice
lives in one machine-local file and is invisible to review, rollback and a fresh install.

This ADR adds that second lane. It does not move anything into the first.

## 4. The upstream mechanism

Sourced from `code.claude.com/docs` via Context7, 2026-10-02. Every claim below is quoted or
directly paraphrased from the docs; §7 lists what the docs do **not** settle.

### 4a. The two keys are a documented pair

> `extraKnownMarketplaces` registers a marketplace on each machine, and `enabledPlugins`
> names the plugins to install and enable from it.
> — *Plugins / org, "Pre-install and require plugins"*

That is literally the fleet pattern, and the fleet already uses the first half.

### 4b. `enabledPlugins` takes `true` **or** `false`

> A plugin whose id appears in managed settings `enabledPlugins`, as `true` or `false`.
> — *Plugins / loading, "Name conflicts"*

So declarative **disable** is a first-class upstream capability, not something to emulate.

### 4c. Precedence is per plugin id, and managed is absolute

> If you set a plugin to `false` in `~/.claude/settings.json` and it still loads, a `true` in
> a higher-precedence source is overriding it. […] The message names the source that
> overrode you: `project`, `project, gitignored`, `cli flag`, or `managed`.
> — *Plugins / loading, "Find where a plugin is enabled"*

Highest to lowest: **managed → CLI flag / `--plugin-dir` → project-local → project → user.**
Managed is strong enough that a sideloaded copy is refused outright:

> `--plugin-dir copy of "<name>" ignored: plugin is locked by managed settings`

`enabledPlugins` is a **map**, so it resolves per id — unrelated ids in a lower scope are
untouched. (The "lists merge instead of overriding" rule in *Settings precedence* governs
array keys such as `permissions.allow`; it does not apply here.)

### 4d. `claude-plugins-official` needs no source

> No external source declaration is needed since the official marketplace name is restricted
> to the official Anthropic source.
> — *Plugins / relevance*

**This repo currently declares an explicit HTTPS URL for it** (`home.nix`, the
`claude-plugins-official` entry). An earlier revision of this section called that URL
"removable" and the removal "strictly better", hedged as *not yet measured*. **It has since
been measured, and it is false: DO NOT REMOVE IT.**

`extraKnownMarketplaces` **requires** `source`. An entry of `{}` registers nothing and yields
`No marketplaces configured` — measured 2026-10-02 against an isolated `CLAUDE_CONFIG_DIR` by a
peer session, and corroborated here against the live file: all **8** registered marketplaces
carry a `source` key and none is name-only. The reference describes the value as a map from
marketplace name to an object *with* `source`. The name-only form belongs to
`pluginSuggestionMarketplaces` and to allowlists, not to registration.

So the "second source of truth" worry is real in principle and moot in practice — there is no
first source to defer to. Deleting that URL on the strength of the old sentence would silently
stop the marketplace registering, which is this document's own subject matter: a declaration
that is never read, in reverse.

**Why this correction arrives here rather than in #755.** The fix was pushed after #755 had
auto-merged, so `main` never received it and every branch cut from `main` inherited the wrong
text. That is the race `.claude/rules/pr-title.md` records as #567 — auto-merge lands a PR the
moment checks go green, so a branch you are still correcting can merge out from under you.

### 4e. The lockdown keys already in use

`modules/darwin/claude-managed-settings.nix` already carries `strictKnownMarketplaces` and
`disableSideloadFlags`. Those constrain **where plugins may come from**; they say nothing
about which are on. This ADR is the orthogonal axis.

## 5. The operator's design, and the one sentence that cannot be built

The request was for three tiers:

> "assured-minimum" plugins … restored with every activation … **still preserving** the
> system level "adhoc" settings that **overrides+extends** the assured-minimum … and
> **survives activations but not persisted**.

Two of the three are buildable as stated. The third contains a genuine contradiction, and
naming it is the main contribution of this document.

**Extend always works.** An id Nix never names is never touched by activation — that is how
the 39 ad-hoc entries already survive today (`claude-code-settings.nix:108`: *"RIGHT OPERAND
WINS, recursively: the operator's keys survive, Nix's keys are restored"*).

**Override of a floor entry cannot work and be assured at the same time.** For an id Nix
*does* name, the mechanism forces a choice:

| Where Nix declares the id | Operator can override it? | Survives the next activation? | Is it "assured"? |
|---|---|---|---|
| **managed** (root-owned) | **No** — not even temporarily; a sideload is *locked* | n/a | **Yes, absolutely** |
| **user** `~/.claude/settings.json` | Yes (edit it, or a project/local/CLI `true`) | **No** — activation restores Nix's value | Only until the operator changes it |
| **not named by Nix** | Yes | **Yes** | It is pure ad-hoc; there is no floor |

"Assured" and "overridable in a way that survives activation" are the same sentence asking
for a value to be both fixed and not fixed. **There is no mechanism gap here to engineer
around** — this is what the word means.

The resolution is therefore not a clever merge: it is to make the choice **explicit per
plugin**, which is what §6 proposes.

## 6. Proposal — two declarative lanes, operator picks per plugin

```
┌──────────────────────────────────────────────────────────────────────┐
│ assured    -> managed settings (root-owned, macos only)              │
│               true|false · cannot be retracted by ANY lower scope    │
│               for: a plugin the repo structurally needs, or one that  │
│                    must stay OFF for a policy reason                  │
├──────────────────────────────────────────────────────────────────────┤
│ declared   -> ~/.claude/settings.json, via the existing Nix merge     │
│               true|false · re-asserted every activation               │
│               operator may override; the override lasts until the     │
│               next `activate`                                         │
│               for: a reproducible default — the 39 entries' home      │
├──────────────────────────────────────────────────────────────────────┤
│ ad-hoc     -> the same file, ids Nix never names                      │
│               untouched by activation · NOT in VCS · not rolled back  │
│               for: trying something out                               │
└──────────────────────────────────────────────────────────────────────┘
```

Shape (illustrative — not a committed option surface):

```nix
local.claudePlugins.marketplaces.kattakath.plugins = [ … ];   # unchanged: the catalogue

local.claudePlugins.assured = {
  "superhook@kattakath" = true;      # today's alwaysOnNames, promoted to where it is real
  "some-risky@elsewhere" = false;    # a policy OFF nothing can lift
};

local.claudePlugins.declared = {
  "empire@kattakath" = true;         # the reproducible default layer
  "llmstxt@kattakath" = false;       # one of the nine live `false`s, now in VCS
};
```

Properties this buys:

- **Reproducible.** A fresh Mac restores the floor instead of three plugins out of 42.
- **Reviewable.** Enabling `empire` — which changes the default agent of every session via
  the plugin's own `settings.agent` — becomes a diff with a comment, not a click.
- **Rollback-able.** `home-manager rollback` moves the plugin set with the generation.
- **Honest about `false`.** The nine deliberate opt-outs stop being machine-local trivia.
- **#648 preserved.** The `/plugin` toggle still persists for every id in neither map.

Costs, stated plainly:

- **Two maps to understand instead of one list**, and the floor/default distinction has to be
  explained once in `CLAUDE.md` or it will be guessed at.
- **An `assured` entry is unfixable from inside a session** — by design, and that is a real
  foot-gun if someone puts a merely-preferred plugin there. The membership bar for `assured`
  must be written down as tightly as `alwaysOnNames`' is.
- **`declared` makes a UI toggle durable only until the next activation.** That is weaker
  than today's behaviour for those ids, and is the one place this ADR trades away some of
  what #648 bought. Any id the operator wants permanently hand-controlled must simply be left
  out of both maps — which is the default.
- `assured` is **`macos`-only**, since `claude-managed-settings.nix` is a darwin module.
  `nixpi` and `nixvm` would get `declared` only. Acceptable: neither runs interactive
  sessions.

## 7. The five open questions — ALL NOW ANSWERED

**These answers were measured the same day and then LOST for an hour.** The revision carrying
them was pushed to its branch after #755 had already auto-merged, so `main` kept the
unanswered version — and kept a §4d claim that had already been measured false. nix-config's
own `pr-title` rule documents that race (#567 lost five commits to it); it caught two sessions
in opposite directions within an hour, and §4d needed its own PR (#759) to repair. Recovered
from the orphaned branch commit.


Measured or sourced 2026-10-02. Two answers changed the design; one closed a hazard nobody
had asked about.

### 7.1 Does managed `extraKnownMarketplaces` merge with the user file's? — WRONG QUESTION

The no-merge sentence is scoped to **gateway policy versus gateway policy**, not to the
managed file versus user settings:

> That policy's `extraKnownMarketplaces` map doesn't merge **with any other policy's**, so
> list every marketplace the group needs in it.
> — *Plugins / org, "Assign release channels to user groups"*

This fleet has no gateway policies, so the warning never applied. But chasing it surfaced a
real hazard that §6 depends on — 7.2.

### 7.2 THE HAZARD: managed SOURCES are `first-wins`, and a skipped one is silent

> **`"first-wins"`, the default:** Claude Code uses the highest-ranked source that delivers at
> least one policy key and **ignores the rest** rather than merging them. […] Claude Code shows
> **no warning** for the sources it skips.
> — *Managed settings, "How Claude Code combines managed sources"*

Ranking, highest first: **1** remote (server-managed from claude.ai or a gateway) · **2** MDM /
OS policy · **3** `managed-settings.json` + `managed-settings.d/*.json` · **4** HKCU.

**This fleet's `claude-managed-settings.nix` plants rank 3.** So a rank-1 or rank-2 source
appearing with *one unrelated policy key* would silently void the entire root-owned floor —
secret-value denies, attribution keys, `strictKnownMarketplaces`, `disableSideloadFlags` — with
no warning and no eval-time signal. That is a bigger exposure than anything this ADR proposes.

**Measured inert on this machine, today:**

| Rank | Source | State |
|---|---|---|
| 1 | remote / server-managed | `claude doctor`: **"Managed settings (remote): not fetched — requires an Enterprise or Team subscription"**, and **"Organization policy: not applicable to Pro and Max accounts"** |
| 2 | MDM plist | `/Library/Managed Preferences/` **does not exist** |
| 3 | managed file | `managed-settings.json` present; **no `managed-settings.d/`** |

So rank 3 is the only managed source present, and first-wins cannot fire. **The dependency is
the account tier, not the config** — the day this account becomes Team or Enterprise, rank 1
starts being fetched and the floor can be skipped silently. `managedSourcesBehavior = "merge"`
is the documented mitigation (needs ≥ v2.1.242; the fleet runs 2.1.268), and `/status` then
prints `Setting sources` plus a `Skipped sources` line.

**This belongs in `claude-managed-settings.nix` regardless of whether §6 is ever built.** It is
the one actionable item this ADR produced, and it is independent of the plugin question.

### 7.3 Does the official marketplace need a source? — YES. §4d was wrong

See §4d, rewritten. `source` is required for registration; the name-only form is for
`pluginSuggestionMarketplaces` and allowlists. `home.nix` is right as it stands.

### 7.4 How does a managed `enabledPlugins: false` render? — NOT MEASURED, and deliberately so

Answering it requires writing a key into a **root-owned security-policy file**. That is a
system-settings modification, it is declaratively owned by this repo (the
`.nix-config-owned` marker sits beside it), and a hand-edit would be a live policy change on
the operator's only machine. **Not done.** The docs give the adjacent behaviour — a sideload
against a managed entry reports `plugin is locked by managed settings` — which is enough to
design against. If `assured` is ever built, this is measured in a VM, not here.

### 7.5 Does the settings.json write race get worse? — NO. And §6 needs no new writer

`claude-code-settings.nix:112` merges with `jq -s '.[0] * $nix[0]'`. jq's `*` is a **recursive
object merge with the right operand winning**, and it **replaces arrays wholesale**. So:

- `enabledPlugins` is an **object** → Nix's declared ids win per id, the operator's other ids
  survive untouched. **That is already exactly the §6 `declared` lane.**
- The `install -m 600 /dev/null` race at `:132` is a **pre-existing two-concurrent-activations
  hazard** documented in place. Widening the attrset Nix emits adds **no new writer** and no
  new collision surface.

**This is the finding that shrinks §6.** The `declared` lane needs no mechanism at all — only
changing `enabledPlugins = lib.genAttrs alwaysOnIds (_: true)` into a merge of the derived
always-on map with an operator-supplied `attrsOf bool`. The existing merge, re-assert and DAG
ordering already deliver the semantics.

### 7.6 Incidental, and worth keeping: `CLAUDE_CONFIG_DIR` really does isolate

Proven by hash: `~/.claude/settings.json` was byte-identical before and after a probe run
under `CLAUDE_CONFIG_DIR`. This matters because **`CLAUDE_CONFIG_HOME` does not isolate** — an
earlier probe in this repo used it and wrote a test key into the operator's real settings file.
Use `CLAUDE_CONFIG_DIR`, and checksum the real file either side anyway.

## 8. Alternatives considered

| Alternative | Why not |
|---|---|
| **Widen `alwaysOnNames`** | Re-creates the non-durable toggle #648 removed, and its membership rule ("what the repo structurally breaks without") would have to be abandoned to admit ordinary preferences. |
| **Managed settings only, no `declared` lane** | Genuinely assured and simplest to reason about, but every one of the 39 ad-hoc entries becomes unoverridable. Converts a preference store into policy. |
| **User settings only, extended to any name** | Smallest change and keeps today's feel, but a project `.claude/settings.json` outranks it — so nothing is assured, and the word in the request is unearned. |
| **Commit `~/.claude/settings.json` wholesale** | One source of truth, superficially. In practice it is a generated file this repo deliberately does **not** own (`claude-code-settings.nix:124` forces `home.file` off), merged into rather than written. Owning it would clobber the ad-hoc lane entirely. |
| **Leave it imperative** | Status quo: 93% of the effective plugin policy exists on one machine, outside review and rollback, and reproduced by nothing. This is the option the measurement in §2 argues against. |

## 9. Decision

**Originally: not taken** — this document was the deliverable, and §7 was to be measured first.

## 9b. First deliveries through the lane, 2026-10-02

The mechanism landed in #758; **what it delivers** landed separately in #757, and the split was
deliberate rather than tidy: *which* plugins are on is an operator decision, not a mechanism
decision, so the session that built the lane declined to enable four plugins on a peer's
proposal. Four more ids, each the same failure `silent-instruments` had:

| Plugin | State before, measured on the live `settings.json` |
|---|---|
| `prior-art-recon` | **absent** from `enabledPlugins` — a peer session tried to load it and could not |
| `empire` | **absent** |
| `foundation-audit` | present, but only because the operator had clicked it |
| `mac-app-send` | present, same |

Two unusable, two working-but-unreproducible. A fresh machine restored neither — which is the
whole case for this lane, in four lines.

`empire@kattakath = true` is the one entry that changes every session on this machine, via its
manifest's `settings.agent`. It is the enablement **#751 believed a `plugins` entry was
performing**; it was not, and that PR was reverted in #754. Deleting the line is the rollback.

`brag-dossier` stays **out**, though it is merged in skills: the brag subsystem was removed
from this repo at the operator's request, and enabling the plugin would reintroduce that
capability by the back door.

Nix now writes **8** `enabledPlugins` ids where it wrote **3** — read off the rendered option,
not inferred.

## 9a. Amendment, 2026-10-02 — the `declared` lane is built, `assured` is not

What forced the revisit: `silent-instruments` was added to the catalogue in **#753** and, like
`empire` in #751, **enabled nothing**. The same defect twice in three PRs is the argument §2
makes, repeated on a plugin that was actually wanted.

**Split, and why it is a clean split.** All five open questions in §7 are about the `assured`
lane or about moving existing floor members into it:

| §7 | Question | Status for the implemented half |
|---|---|---|
| 1 | Does the **managed FILE**'s `extraKnownMarketplaces` merge? | **Irrelevant.** `declared` writes user scope only; `modules/darwin/claude-managed-settings.nix` is untouched. |
| 2 | Can `claude-plugins-official` drop its explicit `source`? | **Irrelevant** — orthogonal (§4d, incidental find). Still unmeasured. |
| 3 | Does a managed `false` read as policy or bug in `/plugin`? | **Irrelevant.** Only `assured` can emit a managed value. |
| 4 | Should the always-on three move into `assured`? | **Answered: no, not now.** They stay derived in `claude-plugins.nix`, keeping the drift assertion at its `:186`. The two lanes are asserted **disjoint** instead. |
| 5 | Round-trip risk — "a second writer to the same key needs that path re-read" | **Re-read, and there is no second writer.** `programs.claude-code.settings.enabledPlugins` is one Nix option; both activation entries (`claudeCodeSettingsMerge`, `claudeCodeSettingsReassert`) run the **same** `mergeScript` over the **same** `nixSettings` derivation. Widening that option's VALUE adds no writer and changes no activation ordering. The `install -m 600` race named at `claude-code-settings.nix:113` is a **concurrent-`activate`** hazard that predates this and is unaffected. |

So the lane that needed nothing measured is the lane that shipped.

**The invariant #648 bought, restated**, because "three hardcoded names" was never the point:

> Nix may write an `enabledPlugins` key **only for an id a human named on purpose.** For every
> other id — including every id in `marketplaces.*.plugins` — the rendered attrset must carry
> **no key at all**, so `claude-code-settings.nix`'s `jq -s '.[0] * $nix[0]'` (right operand
> wins **per key**) leaves the operator's value, `false` included, exactly as `/plugin` wrote it.

`lib.genAttrs allIds (_: true)` broke it by **deriving** the set from the catalogue.
`local.claudePlugins.declared` cannot: it is an operator-written map of literal ids, and
`allIds` is never its source. Live proof the merge behaves as claimed — 42 ids on this Mac,
**11 `false`**, of which Nix named **3**; the other 39 survived every activation since #648
precisely because no key existed for them.

**What shipped**

- `local.claudePlugins.declared` — `attrsOf bool`, full `<plugin>@<marketplace>` ids.
- `enabledPlugins = cfg.declared // genAttrs alwaysOnIds (_: true)` — floor last, so it wins
  the merge even if the disjointness assertion were deleted.
- Three assertions, each **measured firing** via `extendModules` rather than assumed:
  malformed key; overlap with the always-on three; and a plugin name absent from its own
  marketplace's catalogue — the last skipped when the marketplace is not declared here, since
  `<plugin>@synced` (claude.ai sync) is live and its contents are unknowable at eval.
- `silent-instruments@kattakath = true`, which is what #753 meant.

**Full ids, not bare names** — a change from §6's derived instinct. A bare name resolved
against `marketplaces` structurally cannot express `<plugin>@synced`, and several of the nine
live `false` ids are exactly that shape.

**Still deliberately not done**

- The `assured` lane. §7 q1-q3 stand.
- The nine `false` entries remain machine-local. The lane that can hold them now exists; each
  is an operator preference and moving one is a per-plugin decision, not a sweep.
- `empire` stays unenabled — #754's reasoning is unchanged by a mechanism existing.

**Upstream-first, grepped not remembered.** Pinned home-manager `7b4c5ec4`: `enabledPlugins`
appears in **zero** files under `modules/`, and the whole `programs.claude-code` option surface
(`enable`, `finalPackage`, `enableMcpIntegration`, `configDir`, `settings`, `context`,
`plugins`, `marketplaces`, `agents`, `commands`, `skills`, `lspServers`, `mcpServers`) has no
option for "a marketplace plugin id is enabled". `plugins` is the near miss and is rejected for
an unrelated reason already recorded in `claude-plugins.nix`'s header (it symlinks plugin
**directories** and has no marketplace concept). The route taken is upstream's own freeform
`settings` escape hatch, which this module already drives — a typed, asserted surface over an
existing mechanism rather than a new one.
