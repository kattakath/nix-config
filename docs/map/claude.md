Part of the [repo map](../repo-map.md) — the full fleet architecture.

## Claude Code surface

### MCP after the gateway — the plugin lane is the ONLY lane (2026-10-02)

**Verdict first: there is no MCP infrastructure in this repo any more.** No shared proxy, nothing
listening on `127.0.0.1:8097`, no tunnel, no portal, no `modules/shared/mcp.nix`, no
`infra/cloudflare/mcp-public.nix`, no `local.mcpGateway.*`, no `fleet.publicMcpServers`, no
`mcp-published-parity` check. `https://mcp.kattakath.com/mcp` answers **403**.

**How a server reaches a session now:**

```
an enabled plugin's own .mcp.json      (github:kattakath/skills, or a 3rd-party marketplace)
        │  names a command on PATH
        v
Claude Code spawns one stdio child PER SESSION  —  nothing shared, nothing long-lived
        │
        v  reaped when the session ends
```

- **Claude Code only.** Claude Desktop loads no plugins, so **Desktop has no MCP servers at
  all** — an empty `mcpServers` block, written deliberately (see `claude-desktop.nix` above).
  Cowork, which reaches servers through Desktop's bridge, likewise has none.
- **A launcher that needs a Keychain read is a PATH package in this repo.** A plugin's
  `.mcp.json` can set `env` to literals and passthroughs but cannot run
  `security find-generic-password`, so the credential work stays in a Nix-installed wrapper the
  plugin names by binary name. **`local.gmailMcp` + `packages/gmail-mcp.nix` is the live
  pattern** (four accounts, one launcher each), and `page-lab-pick` / `mcp-nixos` are the same
  arrangement for `page-lab` / `claude-code-nix`.
- **The repo CAN see the credentialed half of its MCP surface — and only that half.** An earlier
  revision of this bullet said "nothing here reads a plugin's `.mcp.json`"; that is **false**.
  `checks.<system>.mcp-launcher-parity` (`modules/parts/checks.nix`) reads every
  `plugins/*/.mcp.json` out of the pinned `kattakath-skills` input at EVAL time and asserts set
  equality between the `nix-mcp-*` commands those plugins name and the launchers `macos` builds
  — so a capability vanishing from, or appearing in, THAT lane does fail a `nix flake check`
  leg, in both directions. What no gate can assert:
  - **that a server ANSWERS.** Set equality is a name join, not a spawn test; the runtime recipe
    is in [`mcp-gateway.md`](../mcp-gateway.md) § How to verify a plugin-owned server actually
    answers, and it is a **procedure**, not a gate.
  - **the three non-`nix-mcp-` lanes**, excluded by construction: `${CLAUDE_PLUGIN_ROOT}`-relative
    commands (which expand only inside the owning plugin), bare nixpkgs binaries, and `npx`
    invocations. Of the 17 servers the pinned plugins declare, 8 are out of scope this way — the
    per-lane breakdown is in [`modules-home.md`](modules-home.md) § `gmail-mcp.nix` +
    `plugin-mcp.nix`.
  - **anything in a marketplace this repo does not pin.** The join covers `kattakath/skills`
    only, and that pin lags the marketplace, which tracks HEAD.
- **Adopting a server is still a declaration, never an imperative install.** `claude mcp add`
  and config-writing installer tools stay denied at user and managed scope
  (`claude-guardrails.nix`, `claude-managed-settings.nix`) — what changed is only *where* the
  declaration lands: the owning plugin's repo, not this one.

History, kept deliberately rather than deleted — [`mcp-gateway.md`](../mcp-gateway.md) is the
retired gateway's full record (roster, counting convention, lane-ownership rule, and the
measurements that outlived it: the Node-20 `node:sqlite` spawn-test trap, the
`owner/repo`-vs-https marketplace-add trap, and the 2026-09-23 call-volume split).

### `claude/` — the GLOBAL agent context (not `.claude/`)

Two top-level directories that are easy to mistake for the project-scoped `.claude/` tree.
They hold the **all-projects, machine-wide** context this repo installs on `macos`:

- **`claude/CLAUDE.md`** → `~/.claude/CLAUDE.md`, via `programs.claude-code.context` in
  `modules/home/default.nix`. That option **replaced a hand-written `home.file` shim** — the
  upstream-first outcome, not a workaround. Holds the user-level rules that apply in every
  session on this machine (AskUserQuestion-for-decisions, the evidence-backed reuse motto, diagrams as
  rendered ASCII, secret-value redaction, git authorship). The repo-root `CLAUDE.md` is
  **project**-scoped and layers on top of it.
- **`claude/output-styles/`, `claude/agents/`, `claude/commands/`, `claude/rules/`** — the
  **Brain Signals** kit, wired by `modules/home/claude-brain.nix` (not `modules/home/default.nix`) through
  `programs.claude-code.{outputStyles,agents,commands,rules}`: the BLUF-first layered output
  style, its companion calibration rule, the `cartographer` read-only architecture subagent,
  and `/task` (goal-locked execution). Its seven `/explain`-family skills live one level up in
  top-level `skills/` — see § Global skills. MOVED HERE from the private nix-personal flake
  2026-09-12: `claude/CLAUDE.md` already carried the same ADHD/dyslexia answer-shape rule in
  prose, so the rule and the mechanism that satisfies it now live together and cannot drift.
  Every option it writes is `attrsOf`-merging, so a private layer or a fork ADDS entries rather
  than replacing the set; the only two scalars (`settings.outputStyle`,
  `settings.alwaysThinkingEnabled`) are `lib.mkDefault`, so a plain assignment downstream wins.
  Two things it must never do, both of which would destroy that seam for everyone: route extra
  global prose through `context` (already defined as a PATH in `modules/home/default.nix` — a second path
  definition is a hard eval error, not a merge; use another `rules.<name>`), or reach for the
  `rulesDir`/`agentsDir`/`commandsDir` forms (upstream asserts `rules` XOR `rulesDir`).

Both are source-path literals (`../../claude/CLAUDE.md`), so they are repo-relative and
content-hashed into the store — see `CLAUDE.md` § Code Style on the two path axes.

### `.claude/commands/`

| Command | What it does |
|---|---|
| `/eval` | stage + `nix flake check` |
| `/hygiene` | LEAN/DRY audit→fix→gate via skill `nix-hygiene` |
| `/update-input` | bump one flake input + commit the lock |
| `/pretooluse-review` | triage `Bash`/`Write\|Edit` gate REJECTIONS from the harness's own OTel `tool_decision` stream (`decision`/`source`/`hook_name`), since prompt-type hooks keep no log of their own |
| `/remember-nix` | capture into the harness's native per-project memory store (outside the repo) |
| `/gmail-account` | add/authenticate/remove a Gmail MCP account — now `local.gmailMcp` + the `gmail` plugin, **not** the retired gateway; see [`gmail-mcp-multi-account-runbook.md`](../gmail-mcp-multi-account-runbook.md) |
| `/routing-review` | triage Claude Code's own OTel tool-decision log for deterministic-routing hardening candidates, see [`claude-code-observability-runbook.md`](../claude-code-observability-runbook.md) |
| `/mcp-scout` | discover → vet → DECLARATIVELY adopt an MCP server **into the owning plugin's `.mcp.json`** via skill `mcp-scout` (there is no gateway to adopt into since 2026-10-02); imperative installer CLIs / config-writing install tools are never used |
| `/userscript` | measure → replay → **publish** a Violentmonkey userscript, via the `page-lab` plugin's method skill + the project skill `userscript-author` (delivery only since 2026-09-14 — nothing is declared or gated in Nix); **no selector ships that was not dumped from the live page**, and `@require`/`@resource` CDN deps are never used |
| `/fleet-doctor` | fleet-wide consistency sweep (branches/worktrees/PRs/CI/cross-repo pins/GC/host re-activation) across every repo in `.claude/skills/fleet-doctor/fleet-repos.txt`, via skill `fleet-doctor`; composes `nix-hygiene`, `git-purity.md`, `pr-title.md` |

`/superhook-review` is **not** in this table and that is not an omission: the `superhook`
plugin ships it. The in-repo `.claude/commands/superhook-review.md` was byte-identical to the
plugin's copy and was deleted 2026-09-30 when superhook moved to plugin-hook delivery — two
copies of one command is a duplicate, not a fallback.

### `.claude/rules/` — always applied

- [`git-purity.md`](../../.claude/rules/git-purity.md) — stage `.nix` files before eval.
- [`pr-title.md`](../../.claude/rules/pr-title.md) — a PR title is the comma-separated list of the
  components the change touches (first-level `nix flake show` output category for flake outputs,
  or a top-level dot-folder with its dot stripped). Also states the default shape: **one PR per
  change, branched off `main`** — a single ~10 min CI gate per PR keeps them independent (the
  old "one open PR per working session" consolidation policy was retired 2026-08-30; the merge
  queue that later justified it was itself removed 2026-09-22).
- [`launchd-naming.md`](../../.claude/rules/launchd-naming.md) — every launchd unit this repo
  authors must expose a `nix-<kebab>` `arg0` basename (never a bare `sh`/`python3`); documents
  the known upstream `/bin/sh` exceptions (`org.nixos.activate-system`,
  `org.nixos.activate-agenix`, `systems.determinate.nix-installer.nix-hook`) that are NOT ours
  and must not be renamed.

### `.claude/hooks/`

Every hook below is **project-scoped** (`.claude/settings.json`): it guards sessions rooted in
this repo only. Two wider tiers carry the fleet-wide floor: user-scope
`modules/home/claude-guardrails.nix` ([`modules-home.md`](modules-home.md) § `modules/home/`)
and, above it on `macos`, root-owned managed scope in
`modules/darwin/claude-managed-settings.nix`
([`modules-darwin.md`](modules-darwin.md) § `modules/darwin/`).

- **`stop-gate.js`** — Stop gate: blocks until configs evaluate clean.
- **`pretooluse-bash-guard.js`** — `PreToolUse:Bash`: deterministic port of the
  Cloudflare-API-call / Cloudflare-docs / approved-CLI policy that
  used to live as a `type: "prompt"` LLM-judged hook; see the file header for the 2026-08-19
  incident that motivated the switch. **Rule 3 — a nudge toward `mcp__desktop-commander__*`
  for file/process listing — was DELETED 2026-10-07 (#812), and the reason is worth knowing:
  it had inverted.** It was written when desktop-commander was one server behind the gateway,
  on the argument that tool preference "is not a safety concern". Once the server was re-adopted
  as the deliberate way AROUND the Bash tool, going through it bypassed this very hook, so the
  nudge was steering routine work off the guarded path. It also named a prefix that cannot
  exist (plugin tools are `mcp__plugin_<plugin>_<server>__<tool>`) and was the ONLY rule here
  with no test coverage — which is how it inverted unnoticed. The opposite rule now lives in the
  desktop-commander plugin, because superhook registers this hook with matcher `"Bash"` and it
  therefore cannot see an MCP tool at all. Also carries **Rule 1c** (a `secret reveal` /
  `security …-w` that would print a secret VALUE into the transcript) and **Rule 1d** (any shape
  that BUILDS on nixpi — `--build-host <pi>`, `deploy --remote-build`, `ssh <pi> nix build`,
  `--builders ssh://<pi>`; the `--target-host` form is deliberately allowed, since it builds
  here and only activates there). Rule 1b — which blocked `deploy` and public-`#macos`
  activation while a private layer existed — was RETIRED 2026-09-15 with that layer.
- **`.claude/hooks/tests/*.sh`** — the case suites for BOTH hooks: three guard-rule suites
  (`rule1-terranix-apply-vs-destroy.sh`, `rule1c-secret-egress.sh`,
  `rule1d-no-build-on-nixpi.sh`) plus `stop-gate-fail-closed.sh`, **gated by
  `claude-config-lint.yml`** as the REQUIRED `Lint .claude config` status check — it BLOCKS a
  merge, it does not merely run. Each asserts BOTH
  halves — the shapes that must block and the shapes that must stay approved — and that the
  hook does not throw. That last assertion is the load-bearing one: `superhook` and the
  script's own `catch` both fail OPEN, so a crash silently disarms every rule at once. Measured
  2026-09-15: retiring Rule 1b removed its constants but left the code referencing them, and
  the guard threw `ReferenceError` on every Bash call — approving everything, including the
  secret-egress and Cloudflare blocks — until these suites were wired into CI. Cases live in a
  FILE rather than an argv because they are execution-shaped by construction and would
  otherwise trip the very rule under test.
- Both are wrapped by **`superhook`** (crash-safety + loop-breaking + logging — the sole
  supervisor for command-type decision hooks). It structurally CANNOT wrap `type: "prompt"`
  hooks, which is why the remaining `Write|Edit` secret-detection gate in
  `.claude/settings.json` stays unsupervised prompt-based — that one is a genuine semantic
  judgment call, unlike the Bash gate's mostly-syntactic rules.
- **How the wrapping is delivered — a PLUGIN HOOK since 2026-09-30, no longer a PATH package.**
  The `superhook` plugin's own `hooks/hooks.json` declares `Stop`, `PreToolUse:Bash` and a
  `SessionStart` digest, each calling `${CLAUDE_PLUGIN_ROOT}/scripts/superhook.js` in front of
  this repo's script. Plugin hook entries auto-merge into the effective hook set, so
  `.claude/settings.json` names **none** of them — and must not, since a settings entry plus a
  plugin entry fires the gate TWICE (the same rule that applies to `autostage-nix` below).
  `packages/superhook.nix` is **DELETED**; so is `.claude/commands/superhook-review.md`, whose
  bytes were identical to the plugin's copy.
  - **The claim this reverses.** Until then, the received wisdom here was that a wrapper
    *cannot* be a plugin hook: `${CLAUDE_PLUGIN_ROOT}` supposedly did not expand in a hook
    command, and a plugin could supposedly only ADD a hook, never wrap one. Measured on Claude
    Code 2.1.268, **both halves are false** — `${CLAUDE_PLUGIN_ROOT}` and
    `${CLAUDE_PROJECT_DIR}` both expand in a plugin hook command, as inline substitution into
    the command string AND as exported process environment.
  - **Still true, and a DIFFERENT measurement:** a plugin's `bin/` reaches the Bash tool's PATH
    but **not** a hook's (2026-09-23). That is why the plugin's commands use an absolute
    `${CLAUDE_PLUGIN_ROOT}` path rather than a bare command name — and why `page-lab-pick`
    remains a PATH package.
  - **`${CLAUDE_PROJECT_DIR}` is the session's LAUNCH CWD, not the git root.** Measured: a
    session started in `<repo>/sub` gets `CLAUDE_PROJECT_DIR=<repo>/sub`. This fleet starts
    sessions in `.claude/worktrees/*` and subdirectories constantly, so each plugin command
    resolves the root with `git rev-parse --show-toplevel`, re-exports it (so `superhook.log`
    lands once per repo, not once per launch directory), and **exits 0 silently if the
    conventional script is absent** — which is exactly what keeps a globally-enabled plugin
    inert in every repo that does not carry these two gates.
  - Expansion is **proven for `SessionStart` only**; `Stop` and `PreToolUse` are **inferred**
    (an isolated `CLAUDE_CONFIG_DIR` cannot authenticate, so those events never fired in the
    probe). The existence test is the defensive answer: a failed expansion yields a
    non-existent path and a no-op, not a crash.
- **`superhook-digest`** — SessionStart digest of supervisor findings, shipped by the same
  plugin as `scripts/superhook-digest.js`; no longer a PATH package and never a file in
  `.claude/hooks/`.
- **`routing-review-digest.js`** — SessionStart nudge for unreviewed
  `user_temporary`/`user_permanent` Claude Code routing decisions; mirrors
  `superhook-digest` exactly, threshold-gated, see
  [`claude-code-observability-runbook.md`](../claude-code-observability-runbook.md).
- **`fleet-doctor-digest.js`** — SessionStart nudge when `/fleet-doctor` hasn't run in a while;
  reads only a local timestamp, no network/git calls, so it stays fast on every session start.
- **`autostage-nix`** — PostToolUse git-purity net. EXTRACTED 2026-09-12 to the
  [`claude-code-nix`](https://github.com/kattakath/ai/tree/main/plugins/claude-code-nix) plugin; it arrives as a
  plugin hook, which is why `.claude/settings.json` no longer lists it (keeping both would
  fire it twice).
- **`nix-home-path-lint`** — same plugin, same extraction. PostToolUse, `.nix` only: flags a hardcoded
  `/Users/<name>/`/`/home/<name>/` runtime-path VALUE per the "Paths — two axes" convention —
  advisory, not a hard gate.

Decoder for what these hooks print: [`claude-hook-messages.md`](../claude-hook-messages.md).

### `.claude/skills/` — project skills

Active only when working in this repo: `nix-hygiene`, `nixpi-firmware-provision`,
`gmail-mcp-accounts`,
`mcp-scout`, `userscript-author` (the FLEET half only — how a script reaches this Mac now that
nothing is declared in Nix; the method lives in the `page-lab` plugin — see
[`packages.md`](packages.md) § Userscripts),
`fleet-doctor` (its own `fleet-repos.txt` manifest lists every repo in scope — add
a line there when a new flake is extracted from this repo, nothing else needs to change).
There is **no `npx skills` CLI lockfile** any more: `skills-lock.json` was deleted 2026-10-02,
having sat at `{"version":1,"skills":{}}` with zero consumers in Nix, CI or hooks. The CLI it
belonged to is rejected outright (`flake.nix:275`, `modules/home/default.nix:1499`), so the flake
path below is the only lane for a global skill — do not re-add the lockfile.

### Global skills

Placed at `~/.claude/skills/<name>/` declaratively by `programs.claude-code.skills`
(`modules/home/default.nix`, darwin-gated) on `darwin-rebuild switch`. Most are sourced from
PINNED `flake = false` inputs (`agent-skills-vercel` = vercel-labs/skills → `find-skills`;
`agent-skills-anthropic-official` = anthropics/skills → `mcp-builder`, `webapp-testing`,
`pdf`/`docx`/`pptx`/`xlsx`), **NOT vendored**; `nix flake update` bumps them.

The `agent-skills-anthropic` input (anthropics/claude-code → plugin-dev + hookify authoring
skills) was REMOVED 2026-09-29. Those eight skills now arrive as the `plugin-dev` and `hookify`
PLUGINS from `claude-plugins-official`, which also carry the agents, commands and hook scripts a
skill-directory mapping drops. Keeping both would have served the same eight skill names from two
upstreams on two unrelated pins.

**Since 2026-09-23 the operator's own skills are NOT on this rail** — they install as plugins from the `kattakath` git marketplace (§ The operator's marketplace). Pinned-era record:

**Since 2026-09-12 the operator's own skills are on that same rail.** `rag`,
`android-phone` and `nix-dev-toolkit` were extracted out of this tree, and since
2026-09-14 live beside the plugins in
[`github:kattakath/ai`](https://github.com/kattakath/ai), pinned as `kattakath-ai`, so the
only difference between "someone else's skill" and "mine" is now who can push to the repo
([`agent-resource-externalization.md`](../agent-resource-externalization.md)):

- **`rag`** — local RAG over the pgvector store: how to ingest and query via the `postgres`
  MCP server and the in-DB `embed()` function (the local-rag capsule's
  `local.rag.pgvector` + `local.rag.ollama`).
- **`capability-broker`** — the "have → rank → find → vet → adopt" protocol for any goal
  that needs a capability the session may lack. Inventory first (skills, deferred MCP tools,
  `claude mcp list`, plugins, connectors, CLIs), lightest capability wins, trust tiers gate
  what may happen unattended, and adoption goes through the harness: a new MCP server is a
  vetted record handed to `mcp-scout`, which since 2026-10-02 lands it in the owning plugin's
  `.mcp.json` rather than in this repo — never a `claude mcp add` (which the
  `claude-guardrails.nix` floor denies anyway). Global because the need shows up in any repo.
- **`android-phone`** — operator knowledge for `packages/android-phone.nix`, global so ADB
  sessions launched from ANY directory know the wrapper's command surface and adb footguns,
  not just sessions rooted in this repo.
- **`nix-dev-toolkit`** — how to make *another* repo self-sufficient with Nix: a working
  `flake.nix` template + `.envrc` (`assets/`), the env-catalogue pattern, a project-local
  Postgres+pgvector stack, and `nix run .#<verb>` lifecycle apps (`references/`). Global
  precisely because the point is to apply it to a repo that does **not** have it yet — its
  `stack-up`/`deploy-prod`/`env-doctor` app names are the template's, **not** flake apps of
  this repo. Carries the Nix/Postgres/Prisma traps (`withPackages` union prefix, socket port,
  the macOS socket-length cap).
- **`harvest`** — the end-of-task half of the loop `capability-broker` starts: gate on worth
  (repeats, hard-won, not already covered), choose skill/subagent/workflow/plugin — or memory
  or project config when it is not an artifact — strip secrets and machine paths, then land it
  as a `kattakath/skills` PR. It mechanises § "Adding to an extracted repo" in
  [`agent-resource-externalization.md`](../agent-resource-externalization.md).
  **No pin bump follows** since 2026-09-23: the marketplace is an https git source with
  `autoUpdate`, so a merge on `kattakath/skills` `main` ships by itself. A `flake.lock` bump is
  needed **only** when the thing you landed is consumed through the `kattakath-skills` INPUT —
  i.e. the `page-lab-pick` PATH package — **the only such consumer left.** (`superhook` became a
  plugin hook 2026-09-30; `mcp.nix`'s `mcpCatalog` was the other, and it went with `mcp.nix` on
  2026-10-02.)

**NOTHING stays vendored** — and in particular there is **no top-level `skills/` directory in
this repo**. Do not re-create one; CLAUDE.md's "Gone on purpose — do not re-add" covers it.

- The Brain Signals `/explain` family (`explain`, `compare`, `map`, `zoom`, `why`, `diagram`)
  ships as the **`brain-signals` plugin** from the `kattakath` marketplace, which is why it
  kept its kit-with-the-output-style property while leaving this tree: the style moved WITH the
  skills, so neither half can drift from the other. `modules/home/claude-brain.nix` keeps only
  what has no plugin form — the **style SELECTION** (`settings.outputStyle =
  "brain-signals:Brain Signals"`, namespaced because a plugin ships it) and the calibration
  **rule** (`rules.brain-signals-context`, since plugins carry no rules). No skills block.

### The operator's marketplace (EXTRACTED 2026-09-12)

> **Update, 2026-09-23 — delivered as a git marketplace, not the pin.** The repo is now
> [`github:kattakath/skills`](https://github.com/kattakath/skills) (renamed from `kattakath/ai`).
> `modules/home/default.nix` registers it as `https://github.com/kattakath/skills.git` with `autoUpdate = true`
> (`local.claudePlugins.marketplaces.<name>.autoUpdate`, which renders
> `extraKnownMarketplaces.<name>.autoUpdate`). Its plugins carry no `version`, so every commit on
> its `main` is a release, gated by that repo's own `validate.yml`. Its top-level `skills/` are
> published as marketplace-root plugins, so the `programs.claude-code.skills` cherry-picks are
> gone, and the Brain Signals kit moved there as the `brain-signals` plugin. The input survives
> as `kattakath-skills`, for the `page-lab-pick` PATH package (plus its `checks.*.page-lab`
> gate) — and, until 2026-10-02, `mcp.nix`'s `mcpCatalog`, which went with that module. A
> plugin's `bin/` reaches the Bash tool's PATH but **not**
> a hook's (measured), which is why `page-lab-pick` is still a package. `superhook` WAS the
> second such package until 2026-09-30, on the stronger claim that a hook wrapper cannot be a
> plugin hook at all — that claim was **measured false** (see § `.claude/hooks/` above), and it
> now ships as a plugin hook. The rest of this section is the pinned-era record.

The operator's OWN Claude Code plugin marketplace is
[`github:kattakath/skills`](https://github.com/kattakath/skills) — **not a tree in this repo** since
2026-09-12 ([`agent-resource-externalization.md`](../agent-resource-externalization.md)). It is **not a
flake pin**: since 2026-09-23 it is registered as the https git source
`https://github.com/kattakath/skills.git` with `autoUpdate = true`, and it is one of **FOUR**
marketplaces — `kattakath`, `claude-plugins-official` (https), `context7-marketplace` (https) and
`xai-grok-build` (the one `/nix/store` path, from a patched pinned input). The `kattakath-skills`
input survives for the `page-lab-pick` PATH package and its check **only** — never for the
marketplace source. (It was `superhook` + `page-lab-pick` + `mcp.nix`'s `mcpCatalog`; superhook
became a plugin hook 2026-09-30 and `mcpCatalog` died with the gateway 2026-10-02.) (The renamed-repo and pinned-era history is the quoted
update block above.)

That repo's `.claude-plugin/marketplace.json` lists its plugins with `./plugins/<name>`
relative sources — the shape every owner-operated marketplace on GitHub uses, measured;
external `{{source:github,…,sha}}` entries are what *catalogs* need, and this is not one.
`modules/home/default.nix` declares it as the `kattakath` entry of
`local.claudePlugins.marketplaces`. The pinned-era form was `source = "${{kattakath-ai}}"` — an
input's **store path**, which carried none of the relative-literal trap the older
`"${{../../plugins}}"` form did, because a store path is absolute and means the same thing from
any file in any flake. Today the source is the https URL, so neither trap applies.

`modules/home/claude-plugins.nix` contributes only the **declaration** for this marketplace:
its `extraKnownMarketplaces` entry (`{ source = "git"; url = …; autoUpdate = true; }`) and the
`<plugin>@kattakath` keys of `enabledPlugins`. It does **not** register or install them — the
`home.activation.claudeCodePlugins` script skips every https marketplace and serves exactly ONE
today (`xai-grok-build`); Claude Code clones and downloads this one itself at session start.

`repin` defaulted true here (the source starts with `/`) and was believed load-bearing on this
reasoning: the store path moves on every content bump and `plugin install` COPIES into
`~/.claude/plugins/cache`, so without a re-pin a bump would serve a previous generation's
content forever. **That premise was measured FALSE on 2026-09-30** — the cache is never read
at load for a directory source — and the `repin` option plus its whole teardown are deleted.
The pinned-era record stands as written; see [`modules-home.md`](modules-home.md)
§ `claude-plugins.nix` for what replaced it
(one `plugin marketplace add`, which only removes a first-session lag).

`repin` here is **`false`** — it derives from `hasPrefix "/" source`, and the source is an https
URL. That matters because `repin` is now the ONLY predicate deciding what activation touches. The
flag's rationale belongs to **`xai-grok-build`**, the one store-path marketplace: its store path
moves on every content bump and `plugin install` COPIES into `~/.claude/plugins/cache`, so without
the re-pin a bump would serve a previous generation's content forever.

Its plugins are the live list at `local.claudePlugins.marketplaces.kattakath.plugins`
(`modules/home/default.nix`) — **14** as of 2026-09-30, and read it rather than any prose here.
Two of them carry write-ups worth keeping:

- **`llmstxt`** — `llms.txt` authoring skill + `/llmstxt` command + a stdlib-only spec
  linter; see the plugin's own `README.md` in [`kattakath/ai`](https://github.com/kattakath/ai).
- **`page-lab`** — userscript authoring AND live-page diagnosis in one unit: the
  measure-before-you-select method, four browser probes, the pre-vetted code patterns, the
  Greasy Fork rulebook, the GM_* portability matrix, a two-way element **picker**, CDP
  diagnosis (performance / network / console), the `/userscript` + `/devtools` + `/pick`
  commands, and `scripts/userscript-meta-lint.sh`. That linter used to be run by
  `checks.<system>.userscripts` here and by nix-personal's twin gate; **both gates went with the
  scripts on 2026-09-14** ([`packages.md`](packages.md) § Userscripts), so the rulebook now has
  exactly one consumer — the
  plugin's own users — plus Greasy Fork's own checks at upload.
  **Merged 2026-09-07 from `userscript-author` + `chrome-devtools`.** They were split on
  2026-09-06 and cross-referenced, which held only while neither needed the other mid-motion.
  The verb that broke it is **pick**: the operator points at an element, the agent measures
  that exact node, reads its cascade, prototypes the override live, dates it in the `WHY`
  block, lints it, and proves it after install — a motion that crossed the boundary four times
  and needed a seam FILE to narrate the crossing. The cost, stated plainly: the diagnosis half
  is no longer adoptable on its own.
  Carries a `devtools-doctor.sh` preflight, a `page-route.sh` front door that probes the five
  routes (raw CDP / chrome-devtools-mcp / claude-in-chrome / Kapture / operator-paste), and a
  **measured** fact table (`references/facts.md`) where every falsifiable claim has an ID, a
  date and a re-measure recipe — because `chrome-devtools-mcp@1.8.0` exposes **29** of the ~57
  tools its generated docs describe (those are written from `main`), so 12 of 13 Memory tools
  do not exist yet. **The Extensions group claim above is stale for this fleet — and the
  measurement that refutes it outlived the option that carried it.** Verified 2026-09-30:
  `--categoryExtensions` works in attach mode against this fleet's Chrome 152 despite upstream's
  own `--help` claiming otherwise; the group's tools DO navigate/list `chrome-extension://` pages
  and service workers once it is passed. **What is gone is the plumbing.**
  `local.mcpGateway.chromeDevtools.*` (`.enable`, `.allowExtensions`, `.port`, `.userDataDir`)
  lived in `modules/shared/mcp.nix`, deleted 2026-10-02 — and `chrome-devtools` itself had already
  moved to the `page-lab` plugin on 2026-09-30, so passing that flag, and owning the security
  tradeoff it accepts, is now that plugin's business and not this repo's. Two things still worth
  carrying over: the server runs in ATTACH mode against **Chromium** (it was Opera Air until
  2026-09-21, when Opera was removed from the Mac), and the attach flag had to be
  **chosen at spawn time** by the `nix-mcp-chrome-devtools` wrapper, because measured
  2026-09-07 no single upstream flag works in both modes a browser can be in: one put into
  debugging from `chrome://inspect/#remote-debugging` 404s every `/json/*` path, so
  `--browser-url` cannot attach; one started with `--remote-debugging-port` serves `/json/*`
  but leaves a **stale** `DevToolsActivePort` whose WebSocket UUID is dead, so `--autoConnect`
  cannot. The wrapper probes `/json/version` first — authoritative when it answers, since it
  carries the live `webSocketDebuggerUrl` — and falls back to the file only when nothing
  answers, which is precisely when the file is fresh. Hence **both** a `port` (probe hint) and
  a `userDataDir` option — and hence the one thing the plugin lane structurally cannot reproduce:
  a `.mcp.json` names a bare command and cannot decide a flag by probing first, so whatever
  replaces that wrapper has to make the probe part of the command it names.

**`seargraph` was deleted, not moved into that repo (2026-09-12).** It was the
`seargraph-langgraph` subagent (LangGraph pipeline design for the private SEARGraph project:
fidelity metrics, constrained optimization, iterative refinement, character embeddings),
wrapped in a plugin as a SCOPING choice — corrected 2026-09-06, the earlier claim that "only a
plugin can ship a subagent" is false. The pinned home-manager DOES expose
`programs.claude-code.agents` (modules/programs/claude-code/options.nix:215, an `agentsDir` at
:341, written by default.nix:334,:337 through lib.nix:38-42 to `${configDir}/agents/<name>.md`).
What that option cannot do is scope the agent: it installs GLOBALLY into `~/.claude/agents/`.

The scoping reasoning was right and the mechanism was wrong. **A project's own
`.claude/agents/` is the canonical way to scope an agent** — no plugin, no marketplace entry,
no Nix wiring, and it cannot be loaded in sessions that have nothing to do with that project.
The file now lives at `SEARGraph/.claude/agents/seargraph-langgraph.md`.

Adding one = a `plugins/<name>/` tree (or a `skills/<name>/` plus a marketplace-root entry)
and a `marketplace.json` entry **in that repo**, then its bare name in
`local.claudePlugins.marketplaces.kattakath.plugins` here. **No pin bump:** a change to an
already-enabled plugin ships from a merge there. Validate with `claude plugin validate .`.

**A SECOND source costs one input and its own entries — no new mechanism.**
`local.claudePlugins.marketplaces` is `attrsOf` and `programs.claude-code.skills` is a
plain attrset, so both already take N. The operator's `ismailkattakath/ai` and
`izzykatt/ai` are deliberately NOT pinned here: they aggregate experiments, and an
experiment has no business being always-on global context on the working Mac. Add one
when it has earned that, or scope it to a project instead.

A **skill** that needs no command/hook/MCP/agent surface belongs in
[`kattakath/ai`](https://github.com/kattakath/ai)'s `skills/`, not in a plugin —
reach for a plugin only when the unit is more than a skill. An agent for ONE project belongs
in that project's `.claude/agents/`, per the seargraph record above.

### Project memory

Lives OUTSIDE the repo, in the harness's own per-project store
(`~/.claude/projects/<slug>/memory/`), whose `MEMORY.md` index is loaded into context at the
start of every session with no hook involved. Written via `/remember-nix`. An in-repo
`memory/` tree surfaced by a `memory-loader.js` SessionStart hook was retired 2026-09-06:
the directory never existed, so the hook never emitted anything, while the native store
quietly held the real entries.

