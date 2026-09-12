# ADR-002: collapse the satellite flakes into nix-config, on flake-parts, as capsules

**Status:** Decided 2026-09-12, not yet implemented. **Supersedes decision #2 of**
[`flake-architecture-strategy-adr.md`](flake-architecture-strategy-adr.md) (ADR-001), which said
*"do not migrate nix-config's core engine to flake-parts"*. ADR-001 is not deleted — §6 below
answers its three objections one by one, and one of them still stands.

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
