# Home Orchestration Layer — Architecture & Phased-Rollout Plan (v4)

> **Status:** v1's direction is approved and preserved in full below. v2 added three
> first-class refinements (§7 Task-shape routing, §8 Deliverable hand-off integrity,
> §9 State reconciliation over memory) empirically motivated by early orchestration use — see
> **Lessons from early orchestration use** below. v3 closed the pre-implementation safety audit
> ([`docs/home-orchestration-audit.md`](home-orchestration-audit.md)): HOME/PROJECT/SPLIT
> misclassifications, the stale-hard-rule migration gate, one factual fix, and
> single-source-of-truth pinning. **v4 folds in the LOCKED
> distribution & packaging model** — replacing v1–v3's
> marketplace-first / `/plugin install` distribution assumption with a declarative
> home-manager `programs.claude-code.plugins` + pinned-flake-input mechanism, and encoding the
> private-repo isolation shape. Where a later revision relaxes or sharpens an earlier rule,
> the affected section is annotated in place and cross-references rather than being rewritten.

> **v4 changelog** (distribution & packaging decisions):
> - **[Dist: primary mechanism]** New first-class **§0.5 Distribution & Packaging** section
>   states the LOCKED model: declarative auto-load via home-manager
>   **`programs.claude-code.plugins`** (the `--plugin-dir` symlinkJoin wrapper), the plugin
>   repo consumed as a **flake input pinned in flake.lock** (updates via `nix flake update`,
>   NOT `/plugin update`), the `marketplaces` HM option explicitly NOT used for install
>   (registration only), the PATH condition (HM must own the `claude` package so the wrapper
>   wins PATH), and the writable-file gotcha (`settings.json` / `.claude.json` / `plugins/`
>   must NOT be read-only store symlinks). Replaces the marketplace-first wording that appeared
>   in v3 §1, §3, §10. *Headline change.*
> - **[Dist: Option 1 private-repo]** §0.5 + §2 encode the chosen **private-repo shape
>   (Option 1)**: the home-rules plugin lives in a PRIVATE repo, wired in ONLY from a private
>   layer/host module so the PUBLIC `nix-config` stays self-contained and buildable by
>   strangers (public repo must NOT reference the private flake input). Ephemeral-container
>   credential caveat noted.
> - **[Dist: audit = publish checklist]** The **public-consumer authoring checklist** (5 rules)
>   is folded into §11 and **explicitly merged with the pre-implementation audit fix list** —
>   the same coupling fixes serve BOTH clean home/project separation AND publish-safety, so
>   audit fixes + publish checklist are ONE work item, not two.
> - **[Dist: phased rollout]** Phase 3 rewritten to the `programs.claude-code.plugins` +
>   private-flake-input-from-a-private-layer mechanism (NOT `/plugin install`/marketplace add).
>   New **Phase 4 public-buildability verification**: the PUBLIC `nix-config` still EVALUATES
>   for a user WITHOUT access to the private input.
> - **[Dist: reconcile stale wording]** Marketplace-first references throughout (§1, §3, §10)
>   are annotated/redirected to §0.5; the marketplace/`.claude-plugin/marketplace.json`
>   structure is retained only as an **OPTIONAL hedge** for a non-Nix / future-public consumer
>   path, never as the Nix auto-load driver.

> **v3 changelog / audit-closure** (each item maps to a check in the pre-implementation audit):
> - **[Audit 1b/3c/4]** `hooks/memory-loader.js` reclassified **HOME → SPLIT (leaning PROJECT)** —
>   home ships a generic memory-surfacer (project-supplied labels + configurable command
>   name, no "Nix repo" text, no hardcoded `/remember-nix`); project supplies the Nix
>   wording. *The single biggest leak.*
> - **[Audit 1c/3b]** `commands/superhook-review.md` kept **HOME only conditionally** — its
>   event→hook-script mapping must become discovery-based (read the actually-configured hook
>   command, not a hardcoded `stop-gate.js`/`delegate-team.js` table) and drop "project
>   policy" wording; otherwise it is reclassified **SPLIT**.
> - **[Audit 1d]** `hooks/superhook.js` stays **HOME**, with a note to strip the git-purity
>   example comment at `superhook.js:22`.
> - **[Audit 3a]** New **migration gate** in Phase 2 + Phase 4: retire *every* stale copy of
>   the pre-§7 hard "manager-for-every-task" rule in the same pass (the `delegate-team.js`
>   hook itself, `docs/orchestration.md`, and the repo `CLAUDE.md` orchestration language),
>   with a Phase 4 verification that **no `delegate-team.js` hook and no hard-rule restatement
>   survives** — a hook-injected hard rule silently overrides §7's relaxation. *Headline gate.*
> - **[Audit 2]** Single source of truth for the orchestration policy = the home
>   `orchestrator-policy` **skill**; home CLAUDE.md stanza and any project CLAUDE.md
>   orchestration section become 1–2 line **pointers**, and `docs/orchestration.md` is deleted
>   (or converted to a pointer). No full restatement of the routing rule in more than one place.
> - **[Audit 1-closing/4]** Factual fix at §2: the reuse-existing-tools + never-push preferences
>   do **not** live in `~/.claude/CLAUDE.md` (which holds only tool-prioritization tables) —
>   they live in the user's **auto-memory**; corrected + scoped out of the plugin below.
> - **[Audit 3d]** Two under-specified spots specified: (a) the generic stop-gate silently
>   approves when no project gate command is declared; (b) the two SessionStart hooks' ordering.

## 0. Lessons from early orchestration use (why v2 exists)

The v1 plan was exercised in a live orchestration session. Three failure modes were
observed directly; each maps to one new first-class section. Recording the rationale
here so future readers know *why* the design tightened.

1. **Single-manager-for-everything overhead on single-shot tasks.** v1's policy
   (inherited from `.claude/hooks/delegate-team.js`) mandates `main → manager → worker`
   for *every* substantive task. In practice, for single-shot work (author one diagram,
   retrieve one document) the mandatory manager hop added latency and an extra failure
   surface while delivering **zero** parallelism benefit — there was nothing to fan out
   or supervise. → addressed by **§7 Task-shape routing** (relaxes the hard rule in §3).

2. **Relay-integrity failures.** Two distinct hand-off breakages occurred: (a) a manager
   reported a plan had been "forwarded" to main when only a *status update* actually
   traversed the hop — the deliverable payload never arrived; and (b) a worker's
   `SendMessage` failed because it addressed an agent **type** (`"general-purpose"`)
   instead of a concrete routable `agentId`. → addressed by **§8 Deliverable hand-off
   integrity**.

3. **Stale-state drift.** The manager repeatedly reported inflated "live worker" counts —
   it counted already-completed workers as still running because it tracked children from
   memory rather than reconciling against runtime reality. → addressed by **§9 State
   reconciliation over memory** (a cross-cutting principle that also hardens §6).

These three refinements are **not** footnotes; they are load-bearing requirements of the
home orchestration layer.

---

## 0.5. Distribution & Packaging (NEW — first-class, LOCKED)

> **v4:** This section is the authoritative distribution model. It **supersedes** the
> marketplace-first / `/plugin install` assumption that appears in §1, §3, and §10 — those
> sections are annotated to point here. Source: the locked distribution decisions (all claims
> verified against current sources).

**Primary mechanism (the Nix fleet) — declarative auto-load, no `/plugin install`.**
The home-rules plugin is loaded declaratively via the **`programs.claude-code.plugins`**
option of the upstream nix-community/home-manager module — **NOT** the `marketplaces` option.

- Verified from the module source (`modules/programs/claude-code.nix`): `plugins` wraps the
  `claude` binary with `--plugin-dir <store-path>` (a `symlinkJoin` wrapper), so Claude
  discovers the plugin files **in place on every launch** — no `/plugin install`, no cache,
  no marketplace round-trip. Fully declarative. `programs.claude-code` is upstream
  (home-manager issue #8227); `claude-code` is in nixpkgs (unfree).
  ([claude-code.nix source](https://raw.githubusercontent.com/nix-community/home-manager/master/modules/programs/claude-code.nix))
- The **`marketplaces` HM option is explicitly NOT used for install** — it only writes
  registration JSON (`extraKnownMarketplaces` + `known_marketplaces.json`); it does **not**
  install/enable. A plugin declared that way is *declared-but-not-installed* (still needs a
  manual `/plugin install`). Registration only. Do NOT rely on it for auto-load.

**The plugin repo is a pinned flake input.**
The home-rules plugin repo is referenced as a **flake input, pinned in `flake.lock`**. Updates
happen via **`nix flake update`**, *not* `/plugin update`. This is what makes the plugin
version reproducible and fleet-consistent — the git SHA in `flake.lock` is the single source
of the deployed plugin version, not a per-host `/plugin` cache.

**PATH condition (load-bearing).**
With home-manager owning **both** the Claude package **and** the `plugins` option, activation
alone installs everything — the user **never** runs `/plugin install` per host. The one
condition: the `claude` on **PATH must be the home-manager-WRAPPED binary**. A foreign
preinstalled Claude (global npm / native installer) that shadows it on PATH bypasses the
`--plugin-dir` wrapper and the plugin silently fails to load. So: **let home-manager manage
the Claude package**, or otherwise ensure the wrapper wins PATH.

**Writable-file gotcha (do NOT store-symlink these).**
`settings.json`, `.claude.json`, and the `plugins/` cache are **mutated by Claude at
runtime**; a read-only Nix-store symlink breaks Claude's sandbox + atomic writes
([issue #52525](https://github.com/anthropics/claude-code/issues/52525)). Symlink only the
**static** content (agents / hooks / skills / rules / CLAUDE.md); land `settings.json` (and
the other mutable files) as a **writable copy** — `mkOutOfStoreSymlink` or an
activation-script copy — never a plain read-only store symlink. Verify the current HM
revision's behavior at wire-up time. This directly reinforces §4 (never write user state into
`${CLAUDE_PLUGIN_ROOT}`) and §6 (mutable orchestration state goes to `${CLAUDE_PLUGIN_DATA}`).

**Private-repo isolation (user's chosen shape = OPTION 1).**
The home-rules plugin lives in a **PRIVATE repo**. To keep the user's **PUBLIC `nix-config`
self-contained and buildable by strangers**, the private plugin input is wired in **ONLY from
a private layer / host module that only the user's own machines import**. The **public repo
must NOT directly reference the private flake input** — a stranger's `nix build` would hit a
hard auth-failure fetching the locked private input.
- Rejected alternatives: (2) make the plugin public; (3) public config points straight at the
  private input + a README override checklist (least clean — breaks public buildability).
- **Ephemeral-container / CI caveat:** VMs, containers, or CI runs that *do* need the private
  input must have git fetch creds (deploy key / token / netrc) **injected at build time** to
  fetch it; a public input would need none. See §6d / Phase-4 note.

**OPTIONAL marketplace hedge (Nix-exit / future-public path).**
Still author the repo in **plugin/marketplace structure** (include
`.claude-plugin/marketplace.json` at the root) so a future non-Nix machine — or a
made-public version — can `/plugin marketplace add` + `/plugin install` natively. This is a
**hedge for a non-Nix / future-public consumer, NOT the Nix auto-load driver.** On the Nix
fleet the marketplace file is inert; the `programs.claude-code.plugins` wrapper is what loads
the plugin.

---

## 1. Plugin anatomy

A Claude Code plugin is a self-contained directory with a `.claude-plugin/plugin.json` manifest (`name`, `description`, optional `version`, `author`, `homepage`, `repository`, `license`) and component dirs **at the plugin root, never inside `.claude-plugin/`**: `skills/<name>/SKILL.md`, `agents/*.md`, `commands/*.md`, `hooks/hooks.json`, `.mcp.json`, `settings.json`, `bin/`, `monitors/monitors.json` ([plugins](https://code.claude.com/docs/en/plugins), [plugins-reference](https://code.claude.com/docs/en/plugins-reference)). A marketplace is a git repo whose `.claude-plugin/marketplace.json` lists plugins and sources; users run `/plugin marketplace add <owner/repo>`, `/plugin install <plugin>@<marketplace>`, refresh with `/plugin marketplace update`, and pull plugin changes with `/plugin update` ([plugin-marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)). Paths inside the plugin use `${CLAUDE_PLUGIN_ROOT}`. Versioning: if `plugin.json` sets `version`, users only update when you bump it; if omitted, the git commit SHA is the version and every commit is an update ([plugins-reference#version-management](https://code.claude.com/docs/en/plugins-reference#version-management)).

> **v4 note — distribution is Nix-native, not marketplace.** The marketplace mechanics above
> (`/plugin marketplace add`, `/plugin install`, `/plugin update`) describe the *plugin format*
> and remain accurate, but on this fleet they are **NOT how the plugin is installed or
> updated** — see **§0.5**. The plugin is auto-loaded declaratively via home-manager
> `programs.claude-code.plugins` and versioned by its pinned flake input; the
> `.claude-plugin/marketplace.json` is kept only as the OPTIONAL non-Nix / future-public
> hedge (§0.5). Because updates flow through `nix flake update` (a pinned SHA), the
> "omit `version` → every commit is an update" concern is moot on Nix; set an explicit
> `version` anyway for the marketplace-hedge consumer and for readable release labels.

## 2. Home vs project-local inventory

| Asset (in `nix-config/.claude/` unless noted) | Target | Rationale |
|---|---|---|
| `hooks/delegate-team.js` (orchestration policy) | **HOME** (re-mechanized into the `orchestrator-policy` skill — §3, §7; hook itself retired — Phase 2/4 gate) | Portable meta-policy; wrong to ship as a per-turn hook. The three project worker-type names (`platform-compiler`/`nix-researcher`/`ci-release-driver`) and the "this repo" voice are stripped; workers described by capability (§5). |
| `hooks/superhook.js` (crash-safe wrapper) | **HOME** | Generic hook-runner infra. **Strip the git-purity example comment at `superhook.js:22`** (only project vocabulary present; functionally portable). |
| `hooks/superhook-digest.js` | **HOME** | Generic incident-log reader; only cross-ref is `/superhook-review` (also HOME). |
| `hooks/memory-loader.js` | **SPLIT** (leaning **PROJECT**) | Mechanism is portable (echo `memory/INDEX.md`, count decisions/findings/values) but 100% of emitted text is Nix-branded and it invokes `/remember-nix`. **HOME half = a generic memory-surfacer taking project-supplied labels + a configurable command name; it MUST NOT emit "Nix repo" text or hardcode `/remember-nix`.** **PROJECT half supplies the "Nix" wording and the `/remember-nix` command.** If the shim is judged overkill, classify the whole thing PROJECT — but do NOT leave it HOME as-is (biggest single leak). |
| `rules/pr-consolidation.md` | **HOME** | Vendor-neutral git-workflow rule (authoritative file; repo CLAUDE.md keeps a pointer). |
| Global `~/.claude/CLAUDE.md` tool-prioritization / cognitive-stack tables | **HOME** | Cross-project standing behavior. **Note (audit factual fix):** the *reuse-existing-tools* and *never-push* preferences do **NOT** live in `~/.claude/CLAUDE.md` — that file holds only the tool-prioritization/cognitive-stack tables. Those two preferences live in the user's **auto-memory** (`MEMORY.md` → `feedback_reuse_existing_actions_scripts.md`, `feedback/never-push-without-explicit-say-so.md`). They are **out of this plugin's migration scope** — the plugin does not (and cannot) "migrate" text from a file that does not contain it; they stay in auto-memory. |
| `output-styles/nix-declarative.md` | PROJECT | Nix-specific voice |
| `agents/{nix-researcher,platform-compiler,ci-release-driver}.md` | PROJECT | Nix/CI-specific |
| `rules/git-purity.md` | PROJECT | Flake `git add` semantics (authoritative prose; CLAUDE.md stays a pointer; the three mechanical enforcers are code, not restatements) |
| `commands/{eval,update-input,remember-nix}.md` | PROJECT | Nix workflows |
| `commands/superhook-review.md` | **HOME — conditional** | Reviews the (home) superhook log. **Keep HOME ONLY IF** its event→inner-hook mapping (currently hardcodes `Stop → stop-gate.js`, `UserPromptSubmit → delegate-team.js` at `superhook-review.md:37-38`) is made **discovery-based** — it reads the *actually-configured* hook command rather than a hardcoded Nix-era table — AND the "out of scope per **project policy**" wording (`:45`) is dropped. **Otherwise reclassify SPLIT** (home ships the generic log-review flow; project supplies its own script mapping). |
| `hooks/autostage-nix.js` | PROJECT | Stages `.nix` |
| `skills/{cloudflare-one,cloudflared-tunnel,nixos-flake-install,utm-vm-provision,nixvm-utm-prebuild-on-devcontainer}` | PROJECT | Fleet-specific |
| Nix sections of `nix-config/CLAUDE.md` | PROJECT | Repo architecture |
| **`hooks/stop-gate.js`** | **SPLIT** | Lifecycle-gate *pattern* is portable; it hard-codes `nix flake check` + devcontainer logic. Home ships a generic gate that shells out to a project-declared command; project supplies the Nix command. **No-op contract (§3d):** if the project declares no gate command, the generic gate **silently approves** (see §6e). |

> **v4 — repo topology (Option 1 private-repo isolation, §0.5).** The HOME assets above ship
> in the **PRIVATE `claude-home` plugin repo**, consumed as a flake input. That private input
> is wired into the fleet **only from a private layer / host module** — the **public
> `nix-config` never references it**. The PROJECT assets stay in the public `nix-config` and
> are what a stranger sees and builds. This is the concrete mapping of §0.5's public/private
> split onto the HOME/PROJECT column here: HOME rows → private plugin repo (private-layer
> wiring); PROJECT rows → public nix-config.

## 3. Inheritance + override model

Cascade, highest→lowest: **Managed → CLI args → Local (`.claude/settings.local.json`) → Project (`.claude/settings.json`) → User (`~/.claude/settings.json`)** ([settings](https://code.claude.com/docs/en/settings)). CLAUDE.md layers similarly. A project `.claude/agents/<name>.md` **overrides a same-named plugin agent**; a plugin is enabled/disabled per settings scope via `enabledPlugins` (persists across updates); project CLAUDE.md text appends/overrides guidance below the home layer.

> **v4 note.** On the Nix fleet, plugin *presence* is not driven by an `enabledPlugins`
> settings entry or a `/plugin install` — it is driven by the home-manager
> `programs.claude-code.plugins` `--plugin-dir` wrapper (§0.5). The cascade/override semantics
> above (project agent overrides plugin agent, project CLAUDE.md appends below home) still
> hold exactly as written — they govern *how the loaded plugin's assets are overridden*,
> independent of *how the plugin got loaded*.

**Hard case — the orchestration policy is a `UserPromptSubmit` hook.** A plugin *can* ship a hook that fires in every project, but the **only** per-project escape from a hook-injected *hard rule* is disabling the plugin — a hook cannot be "softened" by project text. Wrong shape for a standing behavioral rule. Recommendation:

- **Standing behavioral rules** (orchestrator-first policy, PR-consolidation) → **home Skill (+ a short home CLAUDE.md pointer)**, not a hook — advisory, cleanly overridable by a project layer.
- **Deterministic enforcement / dynamic state** (crash-safety, stop-gate, state rehydration §6) → **hooks**.

Migrate `delegate-team.js`'s content into a home **skill** (`orchestrator-policy`); the home CLAUDE.md carries only a 1–2 line pointer to that skill; keep hooks only for enforcement. **The `delegate-team.js` hook itself is retired, not reshipped** (Phase 2/4 gate).

**Single source of truth (audit Check 2).** The `orchestrator-policy` **skill is the one authoritative statement** of the routing policy. Everywhere else is a pointer, never a restatement:

- Home `CLAUDE.md` orchestration stanza → **1–2 line pointer** to the skill.
- Project `CLAUDE.md` "Orchestration model" section → **shrink to a 1–2 line pointer** (or delete).
- `docs/orchestration.md` → **deleted, or converted to a pointer** — its entire reason for existing ("mirror `delegate-team.js`; the hook wins if they disagree") evaporates once the hook is gone.
- **No full restatement of the routing rule in more than one place.** Duplicate prose copies are the drift surface the audit flags; the skill owns the text, everything else references it.

> **v2 amendment (see §7):** The migrated `orchestrator-policy` skill must *not* restate
> v1's "manager hop for every substantive task" as a hard rule. §7's **task-shape routing**
> replaces it: the manager is *reserved for genuinely decomposable/parallel work* and is
> *optional* for single-shot work. Because this policy now lives in an advisory skill /
> CLAUDE.md pointer (not a hook), the relaxation is expressible and project-overridable —
> exactly the shape this section argues for. **This is only true if no `delegate-team.js`
> hook survives** anywhere that enables this plugin (Phase 4 verification): a surviving
> hard-rule hook would silently win over the skill.

## 4. Update-without-clobber

`plugin update` replaces `${CLAUDE_PLUGIN_ROOT}` wholesale — **never write user state there**. User customizations survive because they live *outside* the plugin: project `.claude/` overrides, `~/.claude/` settings/CLAUDE.md, and the `enabledPlugins` entry. Plugin-owned mutable state goes in **`${CLAUDE_PLUGIN_DATA}` → `~/.claude/plugins/data/{id}/`, designed to survive updates** ([plugins-reference#persistent-data-directory](https://code.claude.com/docs/en/plugins-reference)).

> **v4 note.** On the Nix fleet an "update" is a **`nix flake update`** that repoints the
> pinned plugin input to a new SHA and re-activates — the store-path `${CLAUDE_PLUGIN_ROOT}`
> is replaced wholesale by a *new* immutable store path, so the "never write user state into
> `${CLAUDE_PLUGIN_ROOT}`" rule is even more absolute here (the store is read-only). This is
> the same concern as §0.5's **writable-file gotcha**: mutable files (`settings.json`,
> `.claude.json`, `plugins/`) must be writable copies, never store symlinks; mutable
> orchestration state (§6) goes to `${CLAUDE_PLUGIN_DATA}`, which is outside the store and
> survives the flake bump.

## 5. Teams-ready seam

Keep three abstractions engine-agnostic so native Agent Teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, [agent-teams](https://code.claude.com/docs/en/agent-teams)) layers additively: (a) the **coordinator role** as a named skill, not hard-wired to `Agent`/`SendMessage` tool names; (b) the **task ledger** behind a thin read/write shim so it can be swapped for `~/.claude/tasks/`; (c) **worker dispatch** described by capability, not by `subagent_type`. Avoid: hard-coding `run_in_background:true` semantics, the single-manager invariant expressed only in prose, storing agentIds in unstructured context.

> **v2 cross-references:** (b) the task-ledger shim is the same **shared store** that §8
> mandates deliverables land in (not chat relays) — front-running the native Agent-Teams
> shared-task-list model. Avoiding "storing agentIds in unstructured context" is
> reinforced by §8's *address-by-agentId-only* rule and §9's *reconcile-before-acting*
> rule: agentIds and worker tallies are runtime state, reconciled against reality, never
> trusted from memory.

## 6. Compaction / restart resilience (critical)

**(a) Where to persist.** The manager `agentId` + task ledger must NOT live only in main's context (lost on compaction) nor in `${CLAUDE_PLUGIN_ROOT}` (wiped on update / a new store path per flake bump, §4). Persist to **`${CLAUDE_PLUGIN_DATA}` keyed by session id**. **Live-agent enumeration — VERIFIED NEGATIVE:** there is **no documented API** for a running agent to enumerate its live background subagents by id; the SDK's `listSessions()`/`getSessionInfo()` enumerate *past on-disk sessions*, not running agents ([agent-sdk/sessions](https://code.claude.com/docs/en/agent-sdk/sessions)). Re-discovery must come from our own durable record.

**(b) Reconcile-on-resume.** On each main turn — at minimum `SessionStart` and after any detected compaction — main reads the durable record *before* routing or spawning: reuse the manager handle if present; only spawn if empty. The manager reconciles its worker tally against actual completion notifications rather than a remembered count.

**(c) Plugin mapping.** Dynamic state rehydration — a legitimate hook use, distinct from standing-policy injection. Ship a **`SessionStart` rehydration hook** (`session-rehydrate.js`) that reads `${CLAUDE_PLUGIN_DATA}` and injects the remembered handle+ledger; keep the *policy* in the skill (home CLAUDE.md carries only a pointer).

**(d) Agent-Teams seam.** Native Agent Teams already persists team/task state to **`~/.claude/teams/{session-<id8>}/config.json` and `~/.claude/tasks/{session-<id8>}/`** (CONFIRMED, [agent-teams#architecture](https://code.claude.com/docs/en/agent-teams)). That **supersedes** our hand-rolled ledger — keep the `${CLAUDE_PLUGIN_DATA}` layer minimal behind the §5 shim.

**(e) SessionStart hook interaction + generic-gate no-op (audit Check 3d).**
- **Two SessionStart hooks, ordering:** the home `session-rehydrate.js` (§6c) and the project `memory-loader.js` (PROJECT half, §2) both fire on `SessionStart`. They are **independent and order-agnostic**: rehydration injects the manager handle/ledger, memory surfacing echoes the project memory index; neither reads the other's output. If a deterministic order is ever wanted, rehydration runs **before** memory surfacing (orchestration state is set up before project context is displayed) — but correctness does not depend on it.
- **Generic stop-gate no-op contract (SPLIT, §2):** the home generic gate is driven **only** by a project-declared gate command. **When the project declares no gate command (the configured command is absent or empty), the gate exits 0 / approves and emits nothing** — it never blocks and never shells out to `nix`/`devcontainer`/any project path. Blocking behavior exists *only* when a project supplies a concrete command; a bare non-Nix repo with the plugin enabled sees a silent pass-through.

> **v2 amendment (see §9):** §6(b)'s "reconcile the worker tally against actual completion
> notifications rather than a remembered count" is generalized in §9 into a design-wide
> **State reconciliation over memory** principle. The durable record here is the *substrate*
> §9 reconciles against; §9 makes reconcile-before-acting mandatory for *every* agent
> holding counts or handles, not just the manager on resume.

---

## 7. Task-shape routing (NEW — first-class)

**Problem.** v1's inherited policy routes *every* substantive task through
`main → manager → worker`. Early orchestration use showed this is the wrong default for
**single-shot** work: the manager hop is pure overhead (latency + an extra relay that can
fail — see §8) with no fan-out or supervision to justify it.

**Rule.** Main routes by the *shape* of the task, using two crisp criteria evaluated
**before** dispatch:

- **Q1 — Decomposition:** Does the task split into **2+ independent workstreams** that can
  run **concurrently** (fan-out benefit)? (e.g. cross-file changes, multi-part research,
  parallel builds.)
- **Q2 — Supervision:** Does it need **ongoing supervision / reaping of multiple children**
  over time (watchdog duty, staged hand-offs between workers)?

Route accordingly:

| Answer | Path | Who runs it |
|---|---|---|
| **Yes to Q1 or Q2** — genuinely decomposable / parallel / needs supervision | **Manager path** | `main → manager → worker(s)`. The manager owns fan-out, supervision, reaping. |
| **No to both** — single-shot: one worker's output, no decomposition | **Single-shot path** | `main → one worker` directly (a single `Agent` dispatch), **no mandatory manager hop**. |
| **No to both AND trivial** — one-line edit, a lookup, a reply | **Inline** | main handles it directly, no agent. |

**This is an intended RELAXATION of v1's hard single-manager-routing rule (§3).** The
manager is now **reserved for true multi-part orchestration**, not mandated for everything.
**This relaxation is only effective if no `delegate-team.js` hard-rule hook survives** — see
the Phase 2/4 migration gate; a hook wins over this skill.

**Reconciliation with the single-manager invariant.** The invariant still holds *whenever a
manager is used*: there is at most **one** manager per session, and all fan-out flows
through it (§5, §6). v2 only removes the requirement that a manager be used *at all* for
single-shot work. Put differently: "one manager" is unchanged; "always a manager" is
relaxed to "a manager iff the task is decomposable/supervised."

**Guardrails.**
- **Escalation, not silent scope creep:** if a task dispatched on the single-shot path
  *turns out* to be decomposable (the lone worker discovers 3 independent sub-slices), the
  worker reports back and main re-routes through the manager — it does not spin up an
  ad-hoc sibling swarm from a single-shot worker.
- **The single-shot worker is still a real subagent** subject to §8 (address by agentId,
  deliverable to the shared store) and §9 (main reconciles its completion against reality).
- **Home mechanization:** encode Q1/Q2 in the `orchestrator-policy` skill's routing
  preamble (§3), not as a hook — so a project may sharpen or override it.

## 8. Deliverable hand-off integrity (NEW — first-class)

**Problem.** Early orchestration use lost payloads across agent hops: (a) a manager said a plan
was "forwarded" when only a *status update* reached main — the actual content never
traversed the hop; (b) a worker's `SendMessage` failed because it targeted an agent
**type** (`"general-purpose"`) instead of a routable `agentId`.

**Design principle — "results land in a shared store, not passed hand-to-hand."**
Payloads must traverse each hop **verifiably**. Concretely, three requirements:

1. **Deliverables go through a shared store, not chat relays.** A worker writes its
   artifact to a **known filesystem path / shared task store** (the §5 ledger shim →
   ultimately `~/.claude/tasks/`), and hands *the path/handle* up the chain. Deliverables
   are **never re-pasted through successive chat relays** where a hop can drop or summarize
   them into a mere status line. Status messages carry *pointers*; the store carries
   *payloads*.

2. **The receiver confirms receipt of the ACTUAL content, not just that work is "done."**
   A hand-off is complete only when the receiver has **read the artifact at the named path**
   and confirmed its content is present — not when an upstream agent *asserts* completion.
   "Done" without a readable artifact at a known location is treated as a failed hand-off,
   and the receiver requests the path (or re-dispatches) rather than reporting success.

3. **Agents address peers ONLY by concrete `agentId`.** `SendMessage` (and any future
   dispatch/continue call) targets a **specific routable agentId**, never an agent
   **type/role name** (`"general-purpose"`, `"nix-researcher"`, …). Type names are for
   *spawning*; addressing an existing peer requires the id returned at spawn time. IDs are
   runtime state — held in the durable record (§6) and reconciled before use (§9), never
   guessed from a role.

**Positioning vs. native Agent Teams.** This principle **front-runs** the native
Agent-Teams **shared-task-list** model (§5, §6d): Teams already persists tasks/artifacts to
`~/.claude/tasks/{session-<id8>}/` and addresses members by concrete member id. Building the
shared-store + confirm-by-reading + address-by-id discipline now means the eventual cutover
to native Teams is *additive*, not a rewrite — our shim already matches its shape.

## 9. State reconciliation over memory (NEW — cross-cutting principle)

**Problem.** An early orchestration manager reported **stale "live worker" counts** — it counted
already-completed workers as still running because it tracked children from an in-memory
tally that drifted from reality. (Per §6, there is also no live-agent enumeration API, so a
naive in-memory count is the *only* thing a careless agent has — and it lies.)

**Principle (spans the whole design).** **Every agent reconciles against RUNTIME REALITY
before acting on any count or handle — it never trusts an in-memory tally.** Before an
agent (main or manager) makes a routing, spawning, reaping, or reporting decision that
depends on "how many children are live" or "which handle is valid," it must reconcile from:

- the **durable record** (§6a: `${CLAUDE_PLUGIN_DATA}` / the §5 ledger / `~/.claude/tasks/`),
  updated on every spawn and every observed completion; **plus**
- **actual completion signals** — the real completion notifications / reaping results for
  each child, and any available **live-agent enumeration** (used when present, but per §6a
  never *assumed* to exist).

An in-memory number is at most a hint to be *checked*, never the source of truth. A child's
**last self-report is not its current state**: a dormant-completed child can re-emit stale
notifications (cf. CLAUDE.md watchdog duty), so counts are re-derived from durable record +
live signals, not accumulated in the agent's head.

**Ties to the rest of the design.**
- **→ §6 (persistence).** §6's durable record is the substrate this principle reconciles
  against; §6(b)'s reconcile-on-resume is one *instance* of this principle (resume-time),
  now generalized to *every* count/handle decision at *any* time.
- **→ §8 (verifiable hand-off).** Reconciliation and hand-off integrity are the same
  discipline viewed twice: §8 says *payloads* live in the shared store and are confirmed by
  reading; §9 says *counts and handles* live in the durable record and are confirmed against
  live signals. Neither payloads nor tallies are trusted from an agent's memory.
- **→ watchdog duty.** The periodic health-check (CLAUDE.md orchestration model) *is* a
  reconciliation pass: reap silently-finished children, stop hung ones, re-derive the live
  set — reason about each child's *actual* current state, not its stale self-report.

---

## 10. Concrete plan

**Repo:** `claude-home` — a **PRIVATE** git repo (Option 1, §0.5) shipping one plugin
`home-orchestrator/` (skills: `orchestrator-policy`, worker-team helpers, the **generic
memory-surfacer** — SPLIT home half of `memory-loader.js`; hooks: `superhook.js`,
`superhook-digest.js`, `session-rehydrate.js` on `SessionStart`, generic `stop-gate` driver;
`commands/superhook-review.md` — discovery-based; a home `CLAUDE.md` **pointer** stanza). Set
an explicit `version` for readable release labels. **Include a root
`.claude-plugin/marketplace.json`** as the OPTIONAL non-Nix / future-public hedge (§0.5) —
inert on the Nix fleet, where the plugin is auto-loaded via home-manager
`programs.claude-code.plugins` (§0.5), not via `/plugin marketplace add`.

> **v2:** the `orchestrator-policy` skill encodes **§7 task-shape routing** (Q1/Q2 decision
> preamble; manager reserved for decomposable/supervised work), **§8 hand-off integrity**
> (shared-store deliverables, confirm-by-reading, address-by-agentId), and **§9 reconcile-
> before-acting** — and is the **single source of truth** (§3); no full restatement lives
> elsewhere. `session-rehydrate.js` + the `${CLAUDE_PLUGIN_DATA}` durable record are the
> substrate §9 reconciles against.

**Phases:**

**(1) Bootstrap** — scaffold `claude-home` via `claude plugin init`, validate with `claude plugin validate`, test with `--plugin-dir` (the same wrapper mechanism home-manager uses in production, §0.5 — so a local `--plugin-dir` smoke test is faithful to the deployed load path).

**(2) Migrate portable assets** out of nix-config. While re-mechanizing `delegate-team.js` into the `orchestrator-policy` skill, **rewrite its "manager for every task" language to §7 task-shape routing** (do not port the hard rule verbatim; strip the three project worker-type names and the "this repo" voice — describe workers by capability, §5).
- **Genericize the SPLIT assets:** `memory-loader.js` home half becomes a neutral memory-surfacer (project-supplied labels + configurable command name — no "Nix repo" text, no hardcoded `/remember-nix`); `superhook-review.md` mapping becomes discovery-based (read the configured hook command) and the "project policy" wording is dropped; strip the `superhook.js:22` git-purity example comment. **These genericization fixes ARE the publish-safety checklist (§11) — one work item, not two** (see §11).
- **MIGRATION GATE (audit Check 3a — retire every stale copy in the same pass):** in this same pass, retire **EVERY** stale copy of the pre-§7 hard "manager-for-every-task" rule — specifically **(i)** the `delegate-team.js` hook itself (delete; do not reship as a hook), **(ii)** `docs/orchestration.md` (delete, or convert to a pointer to the skill — its "mirror the hook" purpose is gone once the hook is gone), and **(iii)** the repo `CLAUDE.md` "Orchestration model" / "Delegate substantive work" language (shrink to a 1–2 line pointer to the skill). Rationale: a hook-injected hard rule can only be escaped by disabling the plugin, never softened by project text — so any surviving `delegate-team.js` hook silently overrides §7's task-shape-routing relaxation.

**(3) Wire nix-config to consume it — via home-manager, not `/plugin install` (§0.5).**
- Add the private `claude-home` repo as a **flake input pinned in `flake.lock`**, and enable it through the home-manager **`programs.claude-code.plugins`** option (the `--plugin-dir` wrapper auto-loads it on every launch). Ensure home-manager **owns the `claude` package** so the wrapper wins PATH (§0.5 PATH condition).
- **Private-layer isolation (Option 1, §0.5):** the private flake input and its
  `programs.claude-code.plugins` wiring live **ONLY in a private layer / host module** that
  only the user's own machines import. The **public `nix-config` must NOT reference the
  private input** — public buildability by strangers depends on it (verified in Phase 4).
- **Writable-file handling (§0.5):** land `settings.json` / `.claude.json` / `plugins/` as
  **writable copies** (`mkOutOfStoreSymlink` or activation-script copy), never read-only store
  symlinks; symlink only static content.
- **Keep locally in the public nix-config:** only the Nix agents/commands/skills, git-purity,
  autostage, the **PROJECT half of `memory-loader.js`** (Nix wording + `/remember-nix`), and
  any project `stop-gate` config supplying `nix flake check`; the project CLAUDE.md
  orchestration section is reduced to a pointer.
- **NOT** `/plugin marketplace add` + `/plugin install` — that path is the OPTIONAL non-Nix
  hedge only (§0.5), superseding v3's Phase-3 marketplace-install step.

**(4) Verify** — confirm cascade (project agents override, home policy still injected via the skill, rehydration survives a forced `/compact`), **plus the three v2 refinements**: a single-shot task takes the direct `main → worker` path with no manager (§7); a deliverable arrives via a shared-store path and is confirmed by reading, and a mis-addressed (by-type) `SendMessage` is caught (§8); a manager's live-worker count re-derives correctly after a worker completes silently (§9).
- **PUBLIC-BUILDABILITY VERIFICATION (v4, §0.5 Option 1):** confirm the **PUBLIC `nix-config`
  still EVALUATES for a user WITHOUT access to the private input** — e.g. `nix flake check` /
  a host toplevel eval with no private-repo fetch creds present succeeds, because the private
  input is referenced only from the private layer a stranger never imports. Correspondingly,
  confirm that an ephemeral VM/container/CI leg that *does* import the private layer has git
  fetch creds injected at build time (§0.5 caveat). This check is what keeps the public repo
  self-contained and strangers-buildable.
- **MIGRATION-GATE VERIFICATION (audit Check 3a):** explicitly confirm that **NO `delegate-team.js` hook survives** in any settings scope that enables this plugin, and **NO "hard/strict manager-for-everything" restatement** survives in `CLAUDE.md` or `docs/orchestration.md` (the routing rule exists in exactly one place: the `orchestrator-policy` skill). This check is load-bearing: because a hook-injected hard rule can only be escaped by disabling the plugin — never softened by project text — a surviving hook would silently override the §7 relaxation and make the home skill dead on arrival.
- **Verify the SPLIT no-ops (audit Check 3d):** the generic `stop-gate` silently approves in a non-Nix repo that declares no gate command; the home memory-surfacer emits neutral labels (no "Nix", no dangling `/remember-nix`) when the project supplies none.
- **PATH-condition check (§0.5):** confirm the `claude` resolved on PATH is the
  home-manager-wrapped binary (not a shadowing global npm / native install), so the
  `--plugin-dir` wrapper actually takes effect.

Then delete migrated originals.

**Open questions / risks:** hooks-in-plugins fire in *every* enabled project — the stop-gate driver's no-op contract (§6e: silent approve when no project command) resolves this; confirm it holds. The single-manager invariant weakens once advisory (skill) rather than a hard hook — mitigated by the rehydration hook AND the Phase 4 gate that guarantees no competing hard-rule hook survives. `${CLAUDE_PLUGIN_DATA}` session-keying needs a GC story. Time the Agent-Teams cutover so the bespoke ledger is retired, not maintained in parallel. **v2 additions:** define the §7 escalation threshold precisely enough to avoid thrash (single-shot worker discovering decomposable work → re-route vs. over-eager manager spawning); decide the §8 shared-store path convention *before* native `~/.claude/tasks/` lands so the shim aligns; ensure §9 reconciliation has a cost-bounded cadence (reconcile on decision points + the long watchdog heartbeat, not tight polling) given there is no live-agent enumeration API (§6a). **v3 addition:** the reuse-existing-tools / never-push preferences live in the user's **auto-memory**, not `~/.claude/CLAUDE.md` — they are out of the plugin's migration scope and stay in auto-memory (do not attempt to "migrate" them into the plugin). **v4 additions:** (a) verify the current home-manager revision's writable-file behavior for `settings.json`/`.claude.json`/`plugins/` (§0.5 gotcha) — HM behavior here is rev-sensitive; (b) settle the private-layer boundary so no public module transitively pulls the private input (Phase-4 public-build gate); (c) provision build-time git creds for the ephemeral/CI legs that DO import the private layer (§0.5 caveat); (d) if/when the plugin is ever made public, the §11 publish checklist is already satisfied by the Phase-2 genericization (one work item).

---

## 11. Public-consumer authoring checklist (MERGES with the pre-impl audit fixes)

> **v4 (from the locked distribution decisions).** These rules apply **IF the plugin is ever made
> public** (or consumed on a non-Nix machine via the §0.5 marketplace hedge). **Critically,
> they are the SAME fixes as the pre-implementation audit's coupling fixes** — decoupling the
> HOME assets from Nix-specific paths/vocabulary (for clean home/project separation) is
> *identical* to making them publish-safe. **Treat the audit fix list (§2 SPLIT/HOME
> genericization + the Phase-2 gate) and this publish checklist as ONE work item, done in the
> Phase-2 migration pass — not two separate efforts.**

1. **Reference bundled files only via `${CLAUDE_PLUGIN_ROOT}/...`** — never absolute paths
   (`~/...`, `/workspaces/nix-config`). *(= the audit's path-decoupling of the
   HOME hooks/commands.)*
2. **No repo-coupled hooks/commands** — especially the audit's `commands/superhook-review.md`
   (make its mapping discovery-based, §2) and `hooks/memory-loader.js` home half (genericize
   or don't ship it in the plugin, §2). Gate on existence or omit. *(= the audit's SPLIT
   genericization — literally the same edits.)*
3. **OS-guard / prefer POSIX** — no macOS-only `pbcopy`, no BSD-only `sed`/`date` flags in the
   shipped hooks/scripts.
4. **Declare / fail-soft on runtimes** — the JS hooks (`superhook.js`, `session-rehydrate.js`,
   the generic memory-surfacer/stop-gate drivers) need `node` on PATH; declare the dependency
   or degrade gracefully, don't hard-crash.
5. **Always set an explicit skill frontmatter `name`** (e.g. `orchestrator-policy`) — else it
   falls back to the install-dir name, which for marketplace installs is a version string that
   **changes every update**. *(Belt-and-suspenders even on Nix, where the load dir is a store
   path; mandatory for the marketplace-hedge consumer.)*

- Sources: [plugin-marketplaces](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces),
  [plugins-reference](https://docs.claude.com/en/docs/claude-code/plugins-reference).
