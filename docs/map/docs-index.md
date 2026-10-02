Part of the [repo map](../repo-map.md) — the full fleet architecture.

## Documentation index — every `docs/*.md`, annotated

Moved here from CLAUDE.md on 2026-09-23. CLAUDE.md is an index and was chronically within
~170 bytes of its 40,000-byte gate; an annotated list of another file's contents is exactly
the "encyclopedia" its own header says belongs here. It keeps a short pointer plus only the
read-this-first warnings that stop someone acting on a superseded design doc.

`checks.<system>.docs-indexed` accepts EITHER file, so this section is what satisfies it for
the ten docs CLAUDE.md alone used to name. Add a new `docs/*.md` row HERE.


- [`docs/repo-map.md`](../repo-map.md) — **the full fleet architecture**: every path, module,
  package and flake output, with the reasoning. The long form of § Navigating the Codebase.
- **The three MCP docs are HISTORY as of 2026-10-02 — the gateway and its Cloudflare portal are
  destroyed.** Each opens with a RETIRED header; read that header before any sentence in the body,
  which is written in the present tense of a system that no longer exists. What is live is
  § MCP after the gateway above: servers come from an enabled plugin's `.mcp.json`, spawned per
  session, nothing shared.
  - [`docs/mcp-gateway.md`](../mcp-gateway.md) — **RETIRED.** The roster, the
    capabilities-vs-entries counting convention, the lane-ownership rule, and the measurements
    that OUTLIVED the gateway and still bind the plugin lane: the Node-20 `node:sqlite`
    spawn-test rule, the `owner/repo`-vs-https marketplace-add trap, the recipe for proving a
    plugin-owned server actually answers, and the 2026-09-23 call-volume split.
  - [`docs/mcp-public-exposure-design.md`](../mcp-public-exposure-design.md) — **RETIRED.**
    The published gateway's design: one connector + one Access app + one service token, exactly
    two hostnames that never grew per server, and the three-objects-per-publish silent-failure
    trap. §10 records the 2026-09-22 two-proxy collapse, §12 the teardown.
  - [`docs/mcp-portal-hardening-plan.md`](../mcp-portal-hardening-plan.md) — **RETIRED, and
    the only one that was never fully executed.** Its surviving value is the two items it
    deliberately did NOT do and why: the provider pin (ADR-004 deferred it) and device posture
    — **zero enrolled devices, so a `device_posture` require evaluates false forever and takes
    the tier OFFLINE.** That trap applies to ANY future Access policy on this account, which is
    why the file is kept rather than deleted.
- [`docs/rdkb-gateway-contract.md`](../rdkb-gateway-contract.md) — the **HTTP contract**
  of the household's Rogers CGM4981 gateway (RDK-B firmware): auth, the server-side
  lockout counter, session lifetime, CSRF, the JSON log endpoint and why entity depth
  varies per page — every claim cited `file:line` against Apache-2.0 `rdkcentral/webui`,
  which **is** this device's UI source. Carries an explicit confirmed-vs-unconfirmed
  table. Read before writing anything that talks to the gateway; it also records why
  monitoring must NOT be built on it (the Cloudflare tunnel is the better WAN signal).
- [`docs/local-rag-upstream-postgres-evidence.md`](../local-rag-upstream-postgres-evidence.md)
  — the **upstream-first record for the `local-rag` capsule's Postgres half**: nix-darwin's
  `services.postgresql` exists, was read in full against the pinned rev, and was **REFUTED**.
  Read it before "simplifying" `modules/features/local-rag/pgvector-local.nix` onto that
  option — it looks like a one-line conventionality fix and every way it regresses is silent.
  The load-bearing finding: `initialScript`/`ensureDatabases`/`ensureUsers` are **declared and
  inert**, upstream warning "Currently nix-darwin does not support" them, so the bootstrap can
  never move — which is what kills the partial adoption too. Plus the lane change
  (`launchd.user.agents`, `selfHeals = false`, reached by neither mechanism), the `/bin/sh`
  arg0 that **`ast-grep` structurally cannot catch** because the literal lives in the pinned
  input, the `readOnly` `superUser = "postgres"` that breaks peer auth, and the `dataDir`
  default that initdb's a fresh cluster over a live store. Mechanised by
  `checks.<system>.local-rag-upstream-seam`; carries its own proven-vs-unmeasured table.
- [`docs/secrets-and-keychain.md`](../secrets-and-keychain.md) — agenix operator-only vault,
  the login-Keychain loader, the `secret` CLI.
- **ADRs, in order** — [`ADR-001`](../flake-architecture-strategy-adr.md) (flake-parts for the
  small supporting flakes; **superseded in part**, and its objection 3 still stands);
  [`ADR-002`](../monoflake-capsule-adr.md) (decided **and implemented**: absorbed all seven
  satellites onto flake-parts + `import-tree` as capsules — **read §9 first**, the record of what
  execution found the design got wrong); [`ADR-003`](../externalization-boundary-adr.md)
  (decided, **NOT implemented**: Nix is the **harness**, governance never leaves; skills MAY
  overlay from `$HOME`, **MCP servers may not**).
  [`ADR-004`](../secrets-recovery-and-identity-adr.md) (decided, **Phase 1 of 3 shipped — docs
  + `OPERATOR-ONLY` markers only**: GCP Secret Manager durable, Keychain as cache, Workspace
  canonical; rename + repo split deferred; §7 awaits approval, §8 the conflicts);
  [`ADR-005`](../iac-coverage-adr.md) (decided and **IMPLEMENTED**: Cloudflare + GCP under
  terranix, Workspace not — §8c is its doc-rot record);
  [`ADR-006`](../mcp-gateway-succession-adr.md) (**MOOT since 2026-10-02 — never implemented,
  and the question it asked no longer exists.** It weighed ContextForge as a **PORTAL-layer**
  candidate, not as `mcp-proxy`'s successor; both the proxy and the portal are now destroyed, so
  there is no succession to decide. Kept for the comparison itself, which is reusable if a portal
  is ever wanted again, and for the finding that closed it: a remote portal structurally **cannot**
  inject per-user credentials into a local child — the one axis the Cloudflare portal lost on, and
  the exact thing `local.gmailMcp` now does by keeping the launcher local);
  [`ADR-007`](../agent-interop-adr.md) (decided, **partially implemented**: **ACP** — Zed's
  Agent *Client* Protocol, stdio JSON-RPC — is the rail all three agent CLIs already share, and
  `acpx` is packaged + installed. A2A was REJECTED on transport fit, with the measurement that
  settles it: **0 A2A strings in `claude`/`grok`/`agy`** against 686/2013/188 MCP. **Read §3
  before wiring anything into `claude mcp serve`** — it honours NO deny rule and NO hook, so it
  routes around this repo's entire guardrail floor including the root-owned managed settings.
  §4 closes the Antigravity lane twice over: the YouTube/Drive premise is false (measured
  against its real 57-tool list) and wrapping it breaches its ToS by name. §5a records why
  images go through the `grok` CLI and not `api.x.ai` — the subscription pays for one and not
  the other, and `XAI_API_KEY` silently flips the lane).
  [`ADR-008`](../declarative-plugin-floor-adr.md) (**PARTIALLY ACCEPTED 2026-10-02 — read §9a
  FIRST**: the `declared` lane is BUILT as `local.claudePlugins.declared`, the `assured`
  managed-settings lane is NOT, and §9a tables which of §7's five open questions that split made
  irrelevant — 1-3 all concern the managed FILE, which is untouched). Can the fleet declare a plugin enabled
  **or disabled** in VCS, restored each activation, while ad-hoc choices still survive? Today
  **no, for all but three names**: `cfg.marketplaces.*.plugins` reaches `enabledPlugins` only
  through the hardcoded `alwaysOnNames` filter, and `extraKnownMarketplaces` never reads
  `plugins` at all — which is why **#751 merged and enabled nothing** (reverted in #754), and
  **#753 repeated it** with `silent-instruments`, which is what forced §9a.
  Measured: Nix writes **3** of the **42** live `enabledPlugins` ids; the operator's 39 include
  **9 explicit `false`**, a value Nix cannot emit. **Read §5 first** — it names the one sentence
  in the request that cannot be built: for an id Nix declares, "assured" and "overridable in a
  way that survives activation" are the same value being both fixed and not fixed, so the
  mechanism forces a per-plugin choice between a root-owned **managed** floor (absolute — a
  sideload is *"locked by managed settings"*) and a **user-settings** default (re-asserted each
  activation). §7 holds the five measurements that must land before any code, of which #1 can
  invalidate the whole shape: the docs say *gateway policy* `extraKnownMarketplaces` maps do not
  merge and are **silent** on the managed FILE. §4d is the incidental find —
  `claude-plugins-official` needs **no `source`**, its name being reserved to Anthropic's, yet
  this repo declares an explicit URL for it. This ADR does **not** reopen #648; §3 upholds it);
  [`ADR-009`](../structural-boundaries-adr.md) (**DECIDED 2026-10-02 — documents the EXISTING
  layout, proposes no migration**: the `modules/parts` → class-layer → `modules/features`
  boundary, the one-line rule for which of the **two** `packages/` trees a new package goes in
  (ownership: dies with one capsule or not), and the four MUSTs + three forbids of a new capsule.
  **Read §6 first if you are about to move a file** — it is the table separating the
  **mechanised** half of the boundary (`capsule-must-not-reach-out`,
  `home-must-not-cross-layers`, `checks.*.capsule-registry` — each one FAILS A BUILD) from the
  **convention-only** half, which is every boundary a newcomer actually asks about:
  `darwin`/`nixos`/`home`, and `packages/` vs a capsule's `packages/`. §7 verifies the shape
  against live upstream (blueprint's one-line `packages/<pname>` contract covering both forms,
  its *"the type can be any folder name"* clause, `ryan4yin/nix-config`'s `agents/` + `.agents/`
  + `AGENTS.md` triple mirroring `claude/` + `.claude/` + `CLAUDE.md`) — **with the caveat that
  blueprint is NOT a pinned input**, so that is cited precedent, not a grepped option surface.
  §8 adopts `modules/shared` → `modules/home` as this ADR's own consequence, to be done in its
  own PR with an empty `drv-snapshot.sh --compare` diff. §9 is the honest wart list:
  `packages/next-right-thing/` holds **no package at all** (six scripts, no `default.nix`, zero
  references in `modules/parts/packages.nix`), and 2 of `modules/shared/`'s then-24 `.nix` were
  not home-manager modules — `nix-cache.nix` calls itself *"NixOS-ONLY"* on its own line 3, and
  `nix-ld-libraries.nix` is a `pkgs:`-taking function, not a module. **§9b is now DONE**: those
  two moved to `modules/nixos/nix-cache.nix` and `modules/_lib/nix-ld-libraries.nix` on 2026-10-02, so
  the §8 rename has nothing left to mislead on.)
- [`docs/workspace-runbook.md`](../workspace-runbook.md) — Workspace by hand (the provider is
  archived, ADR-005 §3.3): inventory, verify, and the delegation table no CLI can read.
- [`docs/identity-and-offboarding.md`](../identity-and-offboarding.md) — the single lever:
  suspend the Workspace account and every derived login goes with it; the three privilege tiers.
- [`docs/agent-resource-externalization.md`](../agent-resource-externalization.md) — why the
  operator's plugins, skills and userscripts left while the seven satellites came back, and the
  rule it turned on: **a gate must move with the content it gates.**
- [`docs/nixpi-sd-flashing-runbook.md`](../nixpi-sd-flashing-runbook.md) — flashing the `nixpi`
  SD card (full verified `dd` write).
- [`docs/new-mac-runbook.md`](../new-mac-runbook.md) — standing up `macos` from a wiped
  Mac (no key recovery: rotate, don't transport); also the manual steps Nix can't do.
- [`docs/macvm-readd-runbook.md`](../macvm-readd-runbook.md) — re-adding the removed `macvm`
  Tart guest (2026-09-05); what survives in the `tart-vms` capsule.
- [`docs/gmail-mcp-multi-account-runbook.md`](../gmail-mcp-multi-account-runbook.md) — TRUE
  simultaneous multi-account Gmail + a silent-wrong-account failure mode. **LIVE**, and the only
  MCP doc that is: the four accounts moved to the plugin lane on 2026-10-01 (`local.gmailMcp` +
  the `gmail` plugin) and the capability never went down.
- [`docs/claude-code-observability-runbook.md`](../claude-code-observability-runbook.md) — local
  OTel for Claude Code's `tool_decision` telemetry + the `/routing-review` loop.
- [`docs/claude-hook-messages.md`](../claude-hook-messages.md) — decoder for this repo's hook
  messages (why DENYs read as "errors", how to read a prompt-hook denial).
- [`docs/claude-desktop-instructions.md`](../claude-desktop-instructions.md) — the one Claude
  behaviour this repo can't manage declaratively + the canonical "diagrams as ASCII" wording.
- [`docs/answer-shape-evidence.md`](../answer-shape-evidence.md) — the published standards
  (COGA, ISO 24495-1, BDA) and effect sizes behind § Answer shape, so the rules stop being
  re-litigated as taste. **A diagram that carries no data measurably HURTS** (g ≈ −0.4).
- [`docs/false-success-signals.md`](../false-success-signals.md) — six measured instances of TWO
  shapes. **A:** a success signal the system did not produce (`--help` exiting zero, `&& echo "done"`
  after a silent no-op, a NEGATED closing keyword still firing, a clobbered `PIPESTATUS`). **B — a
  false ABSENCE:** `ls` in a worktree branched before the merge "proving" a file does not exist, and
  ten `startup_failure` runs republishing no image while every PR stayed green (a startup failure
  creates no job, so it runs no check). Plus the corollary —
  a gate only ever seen green is not known to gate, and why a fail-closed guard must be checked with
  `nix build` rather than `nix eval`.
- [`docs/terminal-theme.md`](../terminal-theme.md) — the one terminal palette: provider
  contract, per-surface coverage (**4/16** on Terminal.app is an OS ceiling), and why stylix
  and base16.nix were both rejected.
- [`docs/macos-settings-surface.md`](../macos-settings-surface.md) — what `macos` configures
  declaratively, and the TCC/FileVault walls.
- [`docs/osascript-accessibility-tcc.md`](../osascript-accessibility-tcc.md) — the one-time
  Accessibility (TCC) grant for `macos-automator`. **Still accurate despite the gateway's death**:
  TCC scopes the grant to `/usr/bin/osascript`, not to whatever parent spawns it, which is exactly
  why the grant carried unchanged when the server moved to the `mac-app-send` plugin (2026-10-01).
  Renamed from `mcp-gateway-accessibility-tcc.md` on 2026-10-02 for that reason: the grant is
  `osascript`'s, so the subsystem that happened to spawn it does not belong in the name.
- [`docs/open-design.md`](../open-design.md) — OpenDesign's declared/imperative boundary: cask +
  updater kill-switch vs. the app's mutable state. Its MCP server left the fleet 2026-09-22.
- [`docs/photo-system.md`](../photo-system.md) — photo retrieval end to end: the
  durable/derived split between what `photo-describe` writes and what `rclip` keeps.
- [`docs/auto-merge-and-merge-queue.md`](../auto-merge-and-merge-queue.md) — how every fleet
  flake merges itself once CI is green (App token, ruleset). **No merge queue** since
  2026-09-22; §3 records why, and what to re-check before re-adopting.
- [`docs/flakehub-input-freshness.md`](../flakehub-input-freshness.md) — the weekly automated
  `flake.lock` bump flow.
- [`docs/nix-media-cli-extraction-grant.md`](../nix-media-cli-extraction-grant.md) + its
  [study](../nix-media-cli-extraction-study.md) — **HISTORY**: extracted 2026-09, then ADR-002
  brought it back as the `media-cli` capsule. Only the `media-<verb>` rename is open.
