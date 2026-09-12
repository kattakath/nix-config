# ADR-002: collapse the satellite flakes into nix-config, on flake-parts, as capsules

**Status:** **Decided and IMPLEMENTED**, 2026-09-12 — waves 0-7 shipped the same day; wave 8
(`nixosOptionsDoc`) is reported on in §9 and deliberately left at `warningsAreErrors = false`.
**Supersedes decision #2 of** [`flake-architecture-strategy-adr.md`](flake-architecture-strategy-adr.md)
(ADR-001), which said *"do not migrate nix-config's core engine to flake-parts"*. ADR-001 is not
deleted — §6 below answers its three objections one by one, and one of them still stands; its own
Status is now *Superseded in part*.

**Read §9 before trusting §§1-8.** This document is the DESIGN as written before execution. Four
of its "ADOPT" rows did not ship as designed, one of its own mechanisms was measured to change
what the fleet builds, and §7's list of what the collapse gives up was missing an item. §9 is the
correction record; where it and an earlier section disagree, **§9 wins**.

**Deciders:** Ismail Kattakath.

**How this was produced:** eight parallel surveys of the engine, the seven satellites, the
nix-personal seam, CI, the docs surface and the flake-parts ecosystem; then **four independent
architectures** written from the same facts with deliberately opposed biases; then **three judges**
scoring motto / lean / DRY / isolation / migration-risk / docs, with citations verified against
pinned store paths; then a completeness critic and an adversarial reviewer. The winner scored
148/180. Every "ADOPT" below was read in the pinned source, not recalled.

---

## 1. Decision

1. **Absorb all seven public satellite flakes** into `nix-config`. They stop being separate repos
   and separate inputs. (`nix-media-cli`, `nix-tart-vms`, `nix-keychain-secrets`,
   `nix-vast-provision`, `nix-local-rag`, `nix-firmware-secrets`, `nix-cloudflared-connector`.)
2. **Re-engineer the flake on `flake-parts`**, with `import-tree` for the module index.
3. **Preserve each satellite's boundary as a *capsule*** — a directory that may not reach outside
   itself, enforced by a build failure rather than by convention.

The measured effects: `flake.nix` **2219 → ~390 lines**; lock **68 → ~55 nodes (−19%)**; seven CI
pipelines, seven merge queues and seven release dances → one.

## 2. Why a capsule, and why it is not a convention

Deleting seven repo boundaries deletes the only *mechanical* isolation this fleet has. Three of
the four architectures replaced it with a directory convention plus a rule in a document. That is
the same artifact class as the CLAUDE.md index which drifted **16 ways in a single audit** on
2026-09-12. A convention is not a boundary.

The winning design replaces it with two mechanisms, **both pure reuse**:

| Layer | Mechanism | Why it is reuse, not invention |
|---|---|---|
| **File** | a scoped `ast-grep` rule (`files:` + `kind: path_expression` + `severity: error`) riding the **already-existing** `checks.<system>.ast-grep` gate | `files:` is already used by this repo's own `hook-json-parse-must-be-guarded.yml`; `sgconfig.yml`'s header states its purpose is *"mechanise conventions this repo already documents in prose"*. Zero new tools, inputs or gates. |
| **Option** | `lib.evalModules` against a stub host | `nix-tart-vms` **already ships this** as `darwinStubs`. The module system *is* the boundary checker; a bespoke dependency analyser would be a proprietary monolith for a solved problem. |

Both were **measured**, by the design's author and independently reproduced by the judge: the
scoped rule flagged `feat/media/x.nix`, left a byte-identical `feat/tart/y.nix` alone, and exited
non-zero. The option-layer stub failed with `error: attribute 'beta' missing`.

The design also spotted that **`modules/shared/mcp.nix` and `modules/darwin/github-runner.nix`
already are capsules** and promotes them. Reuse of shape.

### Anatomy

```
modules/features/<name>/
  flake-module.nix   the ONLY file anything outside imports
  module.nix         the option surface + ONE `config = lib.mkIf cfg.enable`
  packages/          its derivations
  checks/            its checks, carried over verbatim, + a kill-switch gate
  README.md          rehomed NEXT TO the code it describes
```

`modules/parts/` is the engine (identity, systems, compose, hosts, terranix, docs…) and *may*
reach in. `modules/features/` are capsules and *may not* reach out.

## 3. The off-the-shelf scorecard (the motto)

Adopted, each verified in the pinned store path:

| Need | Module | Replaces |
|---|---|---|
| Flake framework | `flake-parts.lib.mkFlake` | `forAllSystems` folds. **6 of 7 satellites already call it** — the incoming code needs re-homing, not rewriting. |
| Non-perSystem outputs | `options.flake` freeform `lazyAttrsOf` | a custom passthrough |
| **Mergeable** `flake.lib` / `flake.darwinConfigurations` across files | a 4-line `mkOption { type = lazyAttrsOf raw; }`, copying flake-parts' own `nixosConfigurations.nix:11` | `types.unique` would force every seam back into one file — **silently re-creating today's monolith**. The single most important API fact for a modular design. |
| `formatter.<system>` + gate | `treefmt-nix.flakeModule` | `treefmtEval = genAttrs …` + `formatter = forAllSystems …` |
| Pre-commit running the *same* binary as CI | `git-hooks.nix` flakeModule | the hand-wire at `flake.nix:920-928` |
| A module index that cannot drift | `import-tree` | a hand-written `imports = [ … ]` at 28k lines |
| Docs that cannot go stale | `treefmt-nix` `programs.mdsh` | prose that drifts |
| Option docs that cannot drift | `pkgs.nixosOptionsDoc` | ~325 hand-documented option sites |
| The 40k CLAUDE.md budget **as a gate** | `treefmt-nix` `programs.sizelint` | today's cclint *warning* — a 50k CLAUDE.md currently ships green |

**Rejected, because the motto cuts both ways:** `easy-hosts` / `ez-configs` / `lite-config` /
`nixos-unified` (they *emit* configurations; none can carry `lib.mkDarwin { extraHomeModules }`),
`numtide/devshell`, `srid/flake-root` (unmaintained; treefmt-nix already defaults `projectRoot`),
`hercules-ci-effects`, `process-compose-flake`. `vic/flake-file` **deferred** — genuinely good, but
it *owns* `flake.nix` and taking it during a migration makes a failed migration undebuggable.

**`deploy-rs` has no `flakeModule`** — grepped the pinned source. `flake.deploy`, `flake.lib.*`
and `darwinConfigurations` stay hand-written in the freeform `flake` attr. Said out loud rather
than implying flake-parts modularises them.

### `flake-parts` partitions — nominated, then rejected on measurement

The hypothesis was that partitions would keep the 15 `flake = false` content pins out of
nix-personal's lock. **Measured: 54 → 52 nodes.** It does not solve the nominated problem — those
pins are consumed by `programs.claude-code.skills` *inside* `darwinConfigurations.macos`, i.e.
inside nix-personal's own `mkDarwin` seam, so they cannot move. Cost: a `./dev/flake.lock` that
*cannot* follow the parent nixpkgs (flake-parts' own `dev/flake.nix` says so) — a second drifting
nixpkgs. Revisit for future dev-only tooling.

## 4. Blocking corrections found by adversarial review

The architecture is sound; **the migration plan was not shippable as written.** 16 risks, 3
blocking. These are corrections to the plan, already folded into §5.

| # | Finding | Fix |
|---|---|---|
| **S1** | Wave 3 deploys the tunnel **over** the tunnel → unrecoverable `nixpi` | re-order; never ship a connector change through the connector |
| **S2** | Moving `packages/templates/` **404s stored GPU templates** — a rented, billed instance boots and provisioning dies, with `nix flake check` green | keep the raw-HTTP path contract; templates do not move |
| **S3** | **`import-tree` does not do what the design says.** Pinned `default.nix:48` — the default filter is *every* `.nix` file not under `/_`, so home-manager modules and `callPackage` functions get fed to the flake-parts module system | use the documented `(import-tree.match ".*/flake-module\\.nix$").addPath`, **plus** a new `checks.capsule-registry` asserting `readDir ./modules/features` equals the registered capsule set — otherwise a misnamed entry file silently drops a whole capsule with green CI |

Also high: `programs.localRag.enable` **is** the two-switch regression the brief forbids (gate
inside each sub-module); two promoted capsules violate the capsule invariant on day one (route
through a typed seam, not a stub); `nix-hardcoded-home-path` is already `severity: error` and will
make Wave 5 unmergeable against four *correct* Tart-guest paths; and **deleting `"*.md"` from
`treefmt.nix` arms mdsh (`bash -c`) over vendored third-party markdown** — `skills/**`,
`plugins/**` must be excluded first, and mdsh given an explicit allowlist of this repo's own files.

## 5. Migration plan

Every wave is independently shippable and revertible. The universal rehearsal gate is
`activate --local <path>` from nix-personal, which evaluates the whole private layer against an
uncommitted branch without touching any lock. The acceptance test is **drv byte-identity**:
`scripts/drv-snapshot.sh` capturing `nix flake show --json`, `macos.system.drvPath`, both NixOS
toplevels, every package/app/check, **and nix-personal's own macos toplevel** via
`--override-input nix-config path:$PWD`. It must carry an honest exclusion list — the four
`${self}`-dependent checks, `apps.macos`, and vast's `rev = self.rev or "main"` change on every
commit — or it cries wolf on day one and gets disabled.

| # | Wave | Gate |
|---|---|---|
| **0** | Baselines + gates, **zero structural change**. Snapshot drvs. Add `typos`/`sizelint`/`mdsh`. Add the 3 ast-grep rules with zero capsules. **Land the ircc → local-rag unpin first** — it is the only hard cross-repo blocker and must come off the critical path. Re-size `nix-ci.yml` *before* ~25 absorbed checks arrive. | rule fixtures pass; drv paths unchanged |
| **1** | `nix fmt` sweep **inside each satellite**, as its own commit — neither big one has ever seen statix or deadnix | each satellite's own CI green; never mixed into the collapse diff |
| **2** | flake-parts conversion, **zero content moves** | **`nix flake show --json` diff must be EMPTY**; drvs byte-identical; `/eval` wall-clock benchmarked, with a measurable regression a legitimate abort |
| **3** | Capsule scaffold + `cloudflared-connector` (241 lines, cleanest) | snapshot the four nixpi firmware names as literal assertions first — a rename is invisible until the next flash (~40 min trip) |
| **4** | `firmware-secrets`, `keychain-secrets`, `vast-provision` | per-capsule standalone-eval + ast-grep green |
| **5** | `tart-vms`, `media-cli` — 70% of the lines, but nix-config consumes 4 attributes and nix-personal **zero** | the 7 module checks + the kill-switch gate |
| **6** | `local-rag` — a coordinated 3-repo change | `modules/shared/mcp.nix`'s `services.pgvectorLocal.databaseUri` still resolves; that seam carries the whole career RAG |
| **7** | Docs generators on; retire 7 rulesets; archive 7 repos; flip ADR-001 to Superseded | `checks.docs-drift` green |
| **8** | *Separately:* `nixosOptionsDoc` `warningsAreErrors = true` | land `false` first; never in a collapse PR |

## 6. Answering ADR-001

- **Objection 1 (blast radius over hard-won knowledge): partially neutralised.** 47% of
  `flake.nix` is comment; those 1067 lines **relocate rather than get rewritten**, and ~600 of the
  1152 code lines are mechanical `genAttrs` → `perSystem` translation provable by an empty
  `nix flake show` diff. The remaining ~550 (`mkDarwin`/`mkNixos`/the tofu builders) carry the
  operational knowledge, and the answer is simply **do not translate them** — keep them as plain
  Nix functions in the freeform `flake` attr.
- **Objection 2 (reusability already met across repos): expires.** The collapse deletes the very
  mechanism ADR-001 named as the substitute, and its own revisit trigger was the supporting-flake
  count changing. It went 5 → 7 → **0**.
- **Objection 3 (unnecessary at 2 systems / 3 hosts): stands, intact.** Host count is not
  changing and **flake-parts buys nothing for three hosts.** The justification is entirely the
  other axis: 28k lines, ~130 `.nix` files, a CLAUDE.md at 85% of its lint ceiling, and 16
  standing docs↔code drift findings. Any pitch claiming host-management benefit is overclaiming.

## 7. What this gives up — stated, not buried

1. **Review legibility.** A PR touching the secret store is today a PR in a repo whose entire
   purpose is the secret store. In-tree it is one hunk in a PR titled `darwinConfigurations, claude,
   docs`. CODEOWNERS cannot require a reviewer a solo maintainer is not. Mitigation: extend the
   PR-title rule so a diff under `modules/features/<x>/` adds `feature:<x>`. That announces; it
   does not gate.
2. **The pinning staging step.** A loader edit reaches the live Mac in 4 hops today, 2 after.
   Honestly, the gate is already weak — the weekly lock PR shows an opaque hash, not the diff —
   but it is a delay on the most dangerous file in the fleet.
3. **Deliberate un-publishing.** `nix-tart-vms` has a 19,795-char README written for strangers.
   With 2 stars / 0 forks across all seven there is no consumer to protect, but it should be a
   decision, not a side effect.
4. **CI budget.** Satellite CI *builds* everything; nix-config's darwin leg is lint-only and
   **builds zero of 44 packages**, so ~42 CLIs' shellcheck never runs on a PR. Absorbing ~25 checks
   roughly doubles the leg. This design **accepts the longer leg** rather than dropping those
   checks, which would be the highest-cost silent loss available.
5. **One merge queue.** A userscript tweak waits behind a tart-runner change.
6. **The ast-grep gate has blind spots** — it cannot see a capsule reaching another via an overlay,
   via `specialArgs`, or via a runtime-constructed store path.
7. **The stubs rot.** `darwinStubs` approximates nix-darwin's option surface by hand; every bump
   can make isolation pass while real composition fails.

8. **126 commits of provenance, and `git blame` with them.** *(Added by §9 — the design shipped
   without this item, which is the most serious omission in this document.)* The absorption is a
   **plain copy**, an operator decision taken to keep seven simultaneous history grafts out of a
   one-day migration. The cost is that every absorbed line's authorship now dates from the
   collapse commit: `git blame modules/features/media-cli/packages/media-queue.nix` answers
   "wave 5", not "the commit that fixed the idle-vs-holding-work bug". **Measured 2026-09-12:
   126 commits across the seven repos** — `nix-keychain-secrets` 32, `nix-firmware-secrets` 20,
   `nix-tart-vms` 19, `nix-vast-provision` 17, `nix-local-rag` 15, `nix-cloudflared-connector` 12,
   `nix-media-cli` 11 — spanning 2026-07-24 to 2026-09-12. None of it is lost; all of it is
   **one hop further away**, in repos the operator archives rather than deletes (an archived
   GitHub repo stays readable and cloneable). The mitigation that was actually taken is prose:
   every capsule `README.md` opens with a **Provenance** note naming its origin repo, and every
   wave commit message is a long-form record of what moved, what did not, and why — which is why
   those messages are as long as they are. Archiving, not deleting, is therefore **load-bearing**
   and not housekeeping: delete an origin repo and this item stops being "one hop further away"
   and becomes a real loss.

**Not fixed by this, and it should not pretend otherwise:** `deploy.nodes.nixpi` is preserved as a
seam **nothing consumes**. The path actually used is nix-personal's `nixos-rebuild --target-host`,
which has no magic rollback and no undo — and every nixpi change in this migration travels it.
Adopting deploy-rs for real, or dropping it, is an orthogonal decision the operator should make;
carrying an unused input plus an uncached Rust build in the devShell is itself a motto violation.

## 8. Found in passing

The adversarial reviewer found a live, unrelated bug: `launchd.agents.ollama-local` was a typo for
home-manager's `launchd.agents.ollama`, so `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS` and
`OLLAMA_KEEP_ALIVE` **had never been in effect**. `ProcessType = "Background"` survived only
because home-manager's own module sets it, which is why the 2026-09-05 power measurement still
looked right — it tested the half that worked. Fixed standalone in `8aa4d9c`.

That failure class — a stale agent name silently creating a dead agent, invisible to
`nix flake check` — is exactly what a 28k-line tree multiplies, and is the argument for the
capsule gates rather than against the collapse.

---

## 9. Correction record — what execution found that the design got wrong

Waves 0-7 shipped on 2026-09-12. **§§1-8 above are the design as written before any of it ran,
and are deliberately not edited** — the point of a correction record is that the two texts can be
compared. Where this section and an earlier one disagree, **this one is what the tree does.**

The architecture held. Every wave's acceptance test — `scripts/drv-snapshot.sh`, comparing all
three host toplevels plus **nix-personal's own `macos` toplevel** — came back with `hosts.tsv`
and `personal.tsv` **IDENTICAL** to the wave-0 baseline. The fleet builds exactly what it built
before the collapse. What follows is where the *plan* was wrong.

### 9.1 Four adoptions from the §3 scorecard did NOT ship as designed

| §3 row | What shipped | Why |
|---|---|---|
| `programs.sizelint` for the 40k CLAUDE.md budget | **`checks.<system>.claude-md-budget`** instead | `treefmt.nix`'s own header scopes that file to tools that **REWRITE**. A size assertion rewrites nothing, and the pre-commit hook **is** the `nix fmt` wrapper — so a checker in the formatter slot fails a commit with nothing to fix. The repo had already made this exact call for ast-grep. **Reusing an off-the-shelf module into the wrong slot is not the motto.** |
| `programs.mdsh` — "docs that cannot go stale" | **not enabled** | The pinned module defaults to `includes = [ "README.md" ]` and treefmt globs match at **any depth**, so one line runs `bash -c` over vendored third-party markdown during a local `nix fmt`. §4 flagged the exclusion problem; it did not say the feature therefore has to wait for its own change with an explicit allowlist. |
| `typos` | **not enabled** | §4 called it "an allowlist project, not a one-line enable" and was right for a stronger reason than stated. Measured with `--write-changes` over the whole tree, it **modified `secrets/*.age` — age CIPHERTEXT** — pulled `wallpaper.png` into scope, and "corrected" `mis` → `miss` inside hook JavaScript. Nothing was committed and every ciphertext was verified byte-identical to HEAD afterwards. |
| `pkgs.nixosOptionsDoc` — "option docs that cannot drift" | **measured, not landed** — see §9.5 | |

**Consequence for §5's wave-7 gate.** That row reads `checks.docs-drift` **green**. There is no
such check and there never was: it was to be produced by `mdsh`, which did not ship. Wave 7 was
gated on `nix flake check` + `checks.<system>.claude-md-budget` + the drv harness instead. A wave
plan that names a gate the same plan has not yet built is a plan that can report success against
nothing.

### 9.2 The capsule's own registration mechanism changed what the fleet builds

This is the single most important correction, and it is a defect in **§2's anatomy**, not in the
migration plan. §2 says a capsule registers through flake-parts' own module registry
(`flake.modules.<class>.<name>`), presented as pure reuse. Measured in wave 4, on a
**home-manager** capsule:

- `types.deferredModule`'s merge **always** wraps a definition in `{ imports = [ … ]; }` (pinned
  nixpkgs `lib/types.nix`, `deferredModuleWith`), and flake-parts wraps **again** for any class
  but `generic` (`extras/modules.nix:14-27`).
- For a NixOS module that is invisible — `config` is attribute-keyed.
- For a home-manager module it is **not**: `home.packages` is a **LIST**, its definitions merge in
  module-collection order, and that order is `buildEnv`'s `paths` order inside
  `home-manager-path` — i.e. **who wins a filename collision**.

Routing `keychain-secrets` through `flake.modules` (tried at both `homeManager` and `generic`)
moved its four CLIs ahead of postgresql and `nix-bedrock-gate` and **changed `darwin-system`'s
drvPath**, with byte-identical package derivations. Importing the same path directly restored it
exactly.

The fix is a second, internal seam declared in `modules/parts/capsules.nix`:
`capsuleModules.<class>.<name>`, `lazyAttrsOf raw`, which passes a definition through
**UNWRAPPED**. Order-sensitive classes use it; the two NixOS capsules stay on `flake.modules` and
get the `_class` stamp for free. The file-level contract is unchanged either way —
`flake-module.nix` is still the only export point.

`tart-vms` needed the raw seam for a second, independent reason the design also missed: both its
runner modules do `imports = [ ./slots.nix ]`, and **the module system dedupes by PATH identity**.
`deferredModule` would have handed `mkDarwin`'s base list two anonymous wrappers instead of two
deduplicable paths.

**Reading: this is what the drv harness is for.** Without it, this substitution is a silent
reordering that nothing in CI would have caught, and §7.7's "the stubs rot" would have been the
least of it.

### 9.3 The boundary has an INWARD hole §7.6 did not list

§7.6 lists the ast-grep gate's blind spots as overlay, `specialArgs`, and runtime-constructed
store paths — all *outward*. The hole found in wave 5 is *inward*: the rule is scoped
`files: modules/features/**`, so it can only see a file **inside** a capsule reaching out. It
cannot see a file **outside** a capsule naming a file **inside** one.

That was not hypothetical. `modules/shared/home.nix` must `pkgs.callPackage` the capsule's
`gitlab-tart.nix` with the **HOST's** pkgs (a derivation built from this flake's perSystem pkgs
would be a different drv), and a `../features/tart-vms/packages/gitlab-tart.nix` literal there is
**not flagged by anything**. The fix is a third seam — `capsuleSources.<capsule>.<name>` in
`modules/parts/capsules.nix`, **paths only** — so `flake-module.nix` stays the only thing outside
a capsule that names a file inside it.

### 9.4 Smaller corrections, in wave order

- **Wave 0's harness was wrong on its first attempt, instructively.** Appending a comment to a
  `.nix` file changed no drvPath — because **the `.nix` file is not an input to the derivation it
  produces**. That is precisely the property "move code, change no build" relies on; a real
  perturbation (editing a `writeShellApplication`'s script text) is caught. Any future docs-only
  pass should expect drv-neutrality **except** where a file is content-hashed into a closure
  (see the last bullet).
- **Wave 1's premise was half wrong.** §5 says the sweep runs "inside each satellite … neither
  big one has ever seen statix or deadnix". It produced **exactly one commit across all seven
  repos** (`nix-tart-vms`, `3f606dc`). The other six, `nix-media-cli` included, were already
  clean.
- **`import-tree` needed one alternation, not a second `addPath`.** §4's S3 got the *defect*
  right and the *remedy* half right: `.match` accumulates with `and` (pinned
  `default.nix:234`), so chaining two matches **intersects** them and loads nothing. The filter
  is one regex with an alternation covering `parts/*.nix` and `features/*/flake-module.nix`.
- **The three-system fold stays three.** Adding `x86_64-linux` to flake-parts' `systems` would
  silently spawn x86 checks, formatter and apps. The devcontainer image and its devShell are
  reached with `withSystem "x86_64-linux"` instead.
- **The `vast-provision` capsule no longer exists (2026-09-12, after this ADR shipped).**
  Everything §4/S2 says about it is still an accurate record of wave 4 — read it as history,
  not as a description of the tree. The whole off-fleet GPU control plane (the six `vast-*`
  CLIs, `runpod-template-apply`, `packages/vast-bootstrap.sh`,
  `packages/templates/provisioner/`, `fleet.vastRawServed` and `vast-scripts-lint`) was
  removed wholesale at the operator's request, so the capsule count is **six**, not seven.
  The S2 hazard that shaped the wave-4 design — "move these files and a BILLED instance
  404s" — did not bite on removal: every stored Vast template pins a full commit SHA rather
  than `main`, so all five kept resolving from git history. `kattakath/nix-vast-provision`
  stays archived and readable.

- **Wave 4 deleted a check and that was the right call.** `checks.<system>.vast-lib-drift` diffed
  nix-config's copy of the boot scripts against the satellite's. Four copies became one, so it
  had nothing left to diff. It was replaced — not dropped — by `vast-scripts-lint`, which
  **shellchecks the surviving copies**: the ones that actually reach a rented instance, which
  nothing had ever linted. Removing a check is only ever acceptable when its subject is gone.
- **The `flake.nix` and lock numbers landed close.** Predicted `2219 → ~390` lines and
  `68 → ~55` nodes. Actual: `2254 → 394` at wave 2 (**404 today**, comment growth), and
  `69 → 56` nodes (**−18.8%**). §1's arithmetic was sound.
- **The capsule rule forces layout the anatomy in §2 does not show.** `..` is an error under
  `modules/features/**` **even when it stays inside the capsule**, so `tart-vms`' four module
  files and `media-cli`'s `package-graph.nix` sit at the capsule ROOT rather than in a nested
  `modules/` or `lib/`, and `tart-vm.nix`'s `defaultTemplate ? ../templates/…` default became a
  mandatory argument the entry file supplies.
- **Two stale references survive on purpose, inside `tart-vms`.** `packages/tart-runner.nix:473`
  and `packages/gitlab-tart.nix:75` still say `modules/…` inside `''…''` **shell script bodies**.
  Fixing them would change the script text, hence the derivation, hence `darwin-system` — so they
  are recorded in that capsule's `flake-module.nix` header rather than silently rotting.
- **A docs-only edit is not always drv-neutral.** `modules/shared/home.nix:1118` content-hashes
  `skills/rag/` into the `macos` closure, so correcting one prose pointer in
  `skills/rag/SKILL.md` **moves `darwin-system`'s drvPath**. Wave 6 measured this, reverted, and
  deferred the edit to wave 7, where it is made deliberately and declared as the wave's only
  host-toplevel delta.

### 9.5 Wave 8, measured — and deliberately not landed

`pkgs.nixosOptionsDoc` was run with `warningsAreErrors = false`, as §5 requires, over each host's
real option tree. **It was not added as a check.** Three measured reasons:

| Tree | Visible options | Lack a description | Of those, declared by THIS repo |
|---|---|---|---|
| `darwinConfigurations.macos` | 1,278 | **8** | **7** — all in the `tart-vms` capsule |
| `nixosConfigurations.nixpi` | 25,345 | 7 | **0** |
| `nixosConfigurations.nixvm` | 25,294 | 0 | **0** |

The seven are `tart.githubRunners.<name>.{appId,cpu,image,image.oci,memoryMB,scope}` and
`tart.gitlabRunner.package`. A textual scan of the whole tree finds **324 option sites**
(302 `mkOption` + 22 `mkEnableOption` — §3's "~325" was accurate) of which **15 `mkOption` sites
carry no `description`**; **10 of those 15 are `darwinStubs`**, the `evalModules` fixture in
`modules/features/tart-vms/checks/module-evaluations.nix` that deliberately approximates
nix-darwin's option surface and should not be documented. The remaining 5 declaration sites are
the 7 rows above (two are submodules whose nested sub-option is also undocumented).

**Why it is not a check:**

1. **At `warningsAreErrors = false` it is a gate that cannot fail.** Wave 0's own standard — "a
   gate that cannot fail is decoration" — applies to this one too. Worse, it does not even
   *report* legibly: an undocumented option comes back as `description: null` rather than an
   absent key, so the obvious `opt ? description` audit returns **zero missing** and is wrong.
   That false negative was hit while producing the table above.
2. **It cannot see most of this repo's options.** `home-manager.users` renders as **one opaque
   row** in a darwin option tree, so `programs.mediaCli`, `programs.keychainSecrets`,
   `local.terminalTheme`, `services.ollamaLocal` / `services.pgvectorLocal` and
   `programs.ungoogledChromium` — five of the seven capsules' public surface — are **not covered
   at all**. The generator does not solve the nominated problem, which is the same measured
   verdict §3 reached for flake-parts `partitions`.
3. **Nothing consumes the output.** Rendering 26k options per host on every CI run, for a
   document no one reads, is the "bigger than the problem warrants" half of the motto.

**The useful follow-up is not the generator, it is the seven descriptions** — and writing them is
drv-neutral (an option's `description` is metadata; the `.nix` file is not an input to the
derivation it produces, §9.4). Flipping `warningsAreErrors = true` remains forbidden until that is
done and until the home-manager blind spot has an answer.

### 9.6 What the operator still owns, off-tree

Wave 7's §5 line says "retire 7 rulesets; archive 7 repos". **No agent did or may do either** —
both are GitHub actions the operator takes directly. The in-tree half is what waves 7-8 delivered:
the docs tell the truth about the post-collapse shape, and
`.claude/skills/fleet-doctor/fleet-repos.txt` no longer sweeps repos that are about to be
archived. Per §7.8, **archive, do not delete** — the origin repos are now the only home of 126
commits of provenance.

**Two more archivings followed on 2026-09-12, and they are NOT this ADR's seven.**
`kattakath/nix-mcp-gateway` and `kattakath/nix-inngest` were archived as **unadopted
extraction candidates**: never satellites, never capsules, never inputs, so nothing arrived
in-tree when they left. The in-tree consequence is the same shape as above — two more lines
out of `fleet-repos.txt`, one merge-queue row out of
[`auto-merge-and-merge-queue.md`](auto-merge-and-merge-queue.md), and ADR-001's
never-satellite set narrowed from two repos to one — so this section stays the single place
that explains why that manifest keeps shrinking. Same §7.8 rule: archived, not deleted.
