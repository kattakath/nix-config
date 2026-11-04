---
name: nix-hygiene
description: >
  Audit and fix this nix-config mono-repo for LEAN/DRY/modular/atomic quality:
  abandoned surface, doc drift, host-scope mistakes, anti-patterns, comment
  rot. Use when asked to "hygiene", "cleanup the repo", "LEAN/DRY pass",
  "audit modularity", "remove bloat", "align with CLAUDE.md", or keep
  nix-darwin/home-manager patterns clean. Composes git-purity, nix fmt,
  flake check, and optional domain doctors — not a substitute for /eval alone.
---

# nix-hygiene

**Floor (already automated):** `nix fmt` / treefmt (nixfmt + statix + deadnix),
ast-grep structural lint (`checks.<system>.ast-grep`), the `path:N` citation lint
(`checks.<system>.line-refs-cite-constructs`), Stop gate + `/eval`
(`git add` → `nix flake check`), CI `nix-ci.yml`.

**The ast-grep floor is SIX rules, and every one `severity: error` — a match FAILS the
build, it is not a review finding.** "Report-only" means only that it never rewrites a
file (unlike treefmt); see `sgconfig.yml`. `ls ast-grep/rules/` is the authoritative
inventory — re-read it each pass rather than trusting this list, which has drifted before:

| Rule (`ast-grep/rules/<id>.yml`) | Catches |
|---|---|
| `nix-hardcoded-home-path` | `/Users/<name>` or `/home/<name>` inside a Nix **string** (a `users.users.<n>.home` declaration is exempt by shape) |
| `launchd-bare-interpreter-arg0` | `Program`/`ProgramArguments` arg0 ending in `/bin/{sh,bash,python3,node,env,…}` instead of a `nix-<kebab>` wrapper |
| `hook-json-parse-must-be-guarded` | a `JSON.parse` in `.claude/hooks/*.js` that no `try` encloses |
| `capsule-must-not-reach-out` | ANY `..` in a **path literal** under `modules/features/**` — escaping or not. `../module.nix` from a `checks/` leaf stays inside the capsule and still fails: a leaf takes what it needs as an ARGUMENT |
| `home-must-not-cross-layers` | `modules/home/` reaching UP via `..` into `features`/`parts`/`hosts`/`infra` |
| `activation-must-not-touch-secrets` | an `activation*` binding naming `secrets-{rehydrate,push,resolve,status}` or `gcloud {secrets,auth}` (ADR-004) |

**This skill:** judgmental hygiene — architecture, host scope, docs↔code,
abandoned experiments, comment rot — then **fix** and **re-gate**.

Canonical conventions + the path index: root [`CLAUDE.md`](../../../CLAUDE.md) (kept lean —
under the 40k context-lint limit). The **full** fleet map lives in
[`docs/map/`](../../../docs/map/) — eleven per-domain files behind the
[`docs/repo-map.md`](../../../docs/repo-map.md) index — with
[`docs/secrets-and-keychain.md`](../../../docs/secrets-and-keychain.md) for the secrets surface.
([`docs/mcp-gateway.md`](../../../docs/mcp-gateway.md) used to be the third — it is **history**
since 2026-10-02: the MCP gateway, `modules/shared/mcp.nix` and the Cloudflare portal are all
deleted. MCP now lives entirely in plugin `.mcp.json` files outside this repo, so the MCP
surfaces here to audit are the launcher packages (`local.pluginMcp`,
`packages/*-mcp.nix`), `checks.*.mcp-launcher-parity`, and `deniedMcpServers` in
`modules/home/default.nix` (plugin twins of claude.ai connectors; fleet-doctor § E4 guards it).)
Do not restate the fleet map here; open those when unsure — and when repo shape changes, fix
**both** the CLAUDE.md one-liner and the `docs/map/` section the index routes it to.

## When to use

| Trigger | Mode |
|---|---|
| "hygiene" / "LEAN DRY" / "cleanup" | Full `audit` (the no-argument run) |
| "fix it" / "clean it up" | `fix`, after the audit |
| Docs feel wrong | `audit scope docs/` (explicit, never the default) |

**Not for:** pure "does it evaluate?" → `/eval`. Pure PR review without fix → a manual diff review (no dedicated command exists in this repo — see §H).

## Modes — a no-argument run is DETERMINISTIC (ADR-013 § 7)

1. **`audit`** — **the default.** Findings only, no edits. Two runs at the same subject SHA
   check the same rules over the same tree.
2. **`fix`** — only when asked. Audit, then apply safe fixes on a branch off
   `origin/<default>`, then format and gate. The fix policy below is unchanged.
3. **`scope <path|host|area>`** — explicit narrowing only. Every rule outside the scope reports
   `notApplicable` (vacuous), so a scoped run exits 2 and is never a baseline.

Never expand into new features. Prefer delete/simplify over new abstraction.

## Subject, rules and output

**Subject = `origin/<default>`, never the checkout.** The checkout may be on any branch, dirty,
or a worktree; none of that is the repo's desired state.

```bash
git fetch origin
def=$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's#^origin/##')
sha=$(git rev-parse "origin/$def")                       # record it: the SARIF carries it
snap="${TMPDIR:-/tmp}/nix-hygiene-$sha"
git worktree add --detach "$snap" "$sha"                 # audit HERE; remove it after
```

**Rules = the catalogue**, [`../doctors/rules.json`](../doctors/rules.json): every `NH-*` entry
has a fixed `level`, a `detect` method, the `evidence` a finding must carry and its
`vacuousWhen`. The checklist below tags each item with its ID. Judgment goes into triage —
is this real, what fixes it — never into choosing what to check or how severe it is.

**Output = SARIF 2.1.0** (ADR-013 § 8), checked by `doctor-report` (`nix run .#doctor-report --`):

| Step | Command |
|---|---|
| start from the catalogue | `doctor-report skeleton hygiene "$sha" > run.sarif` (`tool.driver.rules` + `versionControlProvenance`) |
| one result per rule | `kind` `fail` (one per finding, `level` = the rule's), `pass` (inputs examined > 0, none found) or `notApplicable` (`properties.inputsExamined: 0` = vacuous, never clean) |
| finding identity | `partialFingerprints["findingId/v1"]` = `doctor-report fingerprint <ruleId> <file> <construct>` — a construct, never a line; `locations[]` whenever there is a file |
| check it | `doctor-report validate run.sarif` (OASIS schema + catalogue); `doctor-report verdict run.sarif` exits **0** clean, **2** findings or vacuous, **1** invalid |
| file it | `doctor-report publish hygiene run.sarif` → `${DOCTOR_REPORT_DIR:-${XDG_STATE_HOME:-~/.local/state}/nix-config-doctors}/hygiene/<UTC>.sarif` + a `latest` symlink |
| compare runs | `doctor-report diff <old>.sarif <new>.sarif` → `{new, resolved, persisting}` by fingerprint |

The run's own exit code is the verdict's. A rule the run never reached has no result, and
`validate` rejects the file: unaudited is not clean.

## Path → responsibility map

| Path | Owns | Typical flake output |
|---|---|---|
| `flake.nix` / `flake.lock` | inputs/pins and ONE `mkFlake` call — nothing else | — |
| `modules/parts/` | the flake ENGINE: `mkDarwin`/`mkNixos`, apps, checks, identity | all |
| `hosts/<name>.nix` | host-only deltas | `darwinConfigurations` / `nixosConfigurations` |
| `modules/home/` | cross-host HM + shared options | both |
| `modules/darwin/` | macOS system | `darwinConfigurations` |
| `modules/nixos/` | NixOS system | `nixosConfigurations` |
| `modules/features/` | the capsules; only `flake-module.nix` is imported from outside | all |
| `packages/` | flake apps/packages | `packages` / `apps` |
| `docs/` | runbooks | — |
| `.claude/` | agent skills/commands/rules/hooks/agents | — |
| `infra/` | terranix | `apps` (`*-plan`/`*-apply` per stack — see `docs/map/entry-points.md`) |
| `secrets/` | agenix recipients + ciphertext | — |

This table only adds the **output** column. The full path list (`modules/_lib/`, `claude/`,
`sites/`, `templates/`, `ast-grep/`, …) is ONE source of truth:
[`CLAUDE.md`](../../../CLAUDE.md) § Navigating the Codebase, routed by
[`docs/repo-map.md`](../../../docs/repo-map.md); small convenience paths (`scripts/`,
`.vscode/`, `.devcontainer/`, `.worktreeinclude`) live only in `docs/map/entry-points.md`,
because CLAUDE.md is near its 40k budget. A path missing from both is itself a finding.

**Platform branching:** `lib.mkIf` in `modules/`, not copy-paste across hosts.
**Host gates:** an option flag for per-host divergence — `isMacosHost` (`modules/_lib/is-macos-host.nix`, reading `local.operatorHost`) for the operator's Mac, a `local.*` enable in `hosts/*.nix` elsewhere. Never the hostname: a template consumer can reuse it.

## Checklist (run in order)

### A. Surface inventory

- [ ] (`fix` only, not a rule) `git status` in the checkout you fix from — no surprise WIP.
- [ ] `NH-A-map-drift` — paths still match the CLAUDE.md + `docs/map/` story (no orphan
      modules, no path whose one-liner and map section disagree).
- [ ] `NH-A-app-undocumented` — Flake apps (`modules/parts/packages.nix` + `modules/parts/terranix.nix`) and `nix run`-able
      capsule packages have matching sources and runbook mentions if user-facing; the
      authoritative list is `nix eval .#apps.<system> --apply builtins.attrNames` (`flake show
      --json` nests outputs under `.inventory`).
- [ ] `NH-A-runbook-dead-ref` — reverse: runbooks mention only apps/paths that still exist.

### B. LEAN / abandoned

- [ ] `NH-B-dual-path` — experimental dual paths (e.g. old and new sshd) collapsed to one.
- [ ] `NH-B-commented-block` — commented-out blocks with no near-term intent removed or recorded via `/remember-nix`.
- [ ] `NH-B-dead-option` — dead options, unused `let` bindings (deadnix/statix will catch some — don't rely only on them).
- [ ] `NH-B-vendor-copy` — vendor copies justified with a one-line "why not upstream" comment — and re-checked
      each pass, because the justification expires. The last one, `hm-launchd` (560 lines of
      forked home-manager), was RETIRED 2026-09-14 once the pinned input grew the three
      options it needed. That is the outcome to aim for, not a permanent fork.

### C. DRY / modular / atomic

- [ ] `NH-C-fact-twice` — one path for one fact (e.g. the `~/Downloads` path shape shared conceptually host/guest).
- [ ] `NH-C-ungated-host-list` — no host-specific lists in shared modules without `mkIf` on `isMacosHost` or a `local.*` flag (never the hostname).
- [ ] `NH-C-launchd-name` — launchd BTM basenames: `nix-<activity>` via `modules/home/launchd-launcher.nix` for HM
      agents, or a hand-written `writeShellScriptBin "nix-<activity>"` arg0 for nix-darwin units
      (`launchd-naming.md` item 2 names the one left) — never bare `sh`/`open`. (`mkNixAgent` is gone; see
      `.claude/rules/launchd-naming.md`.)
- [ ] `NH-C-plaintext-secret` — never plaintext in `.nix`; agenix vault vs Keychain rules unchanged.
- [ ] **Already mechanical — spend judgment elsewhere.** Three registry↔consumer invariants
      are enforced, not audited: the drift check covers every `*-plan` app **by construction**
      (`terranix-drift` in `modules/parts/terranix.nix` filters `config.packages` on the suffix);
      every `cron:` workflow pings a heartbeat or sits in the `unwatched` allowlist
      (`checks.<system>.heartbeat-workflow-parity`); the Bash guard knows every `*-apply`
      (`checks.<system>.terranix-guard-knows-every-apply`). What none of them sees: a new
      `*-plan` wrapper with no `passthru.terranixDriftEnv` runs credential-less and shows up
      only at runtime, as a drift-run `error` — that one IS a finding
      (`NH-C-plan-without-drift-env`).

### D. Comments & docs

- [ ] `NH-D-comment-restates` — comments explain **why**, not restate the code.
- [ ] `NH-D-experiment-narrative` — remove "we tried X then Y" experiment narratives unless they prevent a known footgun (one sentence max).
- [ ] `NH-D-runbook-command-drift` — `docs/*-runbook.md` and skill frontmatter match current commands.
- [ ] `NH-D-stale-count` / `NH-D-stale-claim` — no number or status claim the live tree contradicts.
- [ ] Do NOT hand-sweep `path:N` citations into this repo's own files — the
      `line-refs-cite-constructs` check already fails on them. The as-of records it skips
      (ADRs, studies, plans, retired `mcp-*` docs) keep their old numbers on purpose.
- [ ] `NH-D-skill-unlisted` — CLAUDE.md skill/command lists (§ Navigating the Codebase) include this skill after add,
      and `docs/map/claude-code.md` describes it.

### E. Community patterns

- [ ] `NH-E-shim-unjustified` — **upstream-first back-stop.** Every custom shim (`home.file`/`home.activation` used as a
      workaround, an activation script, a "make X see Y" wrapper, a symlink farm) carries a
      one-line justification that the pinned input was grepped and owns no equivalent option —
      per [`.claude/rules/upstream-first.md`](../../rules/upstream-first.md). For a CLI or
      wrapper, that justification must ALSO cover the tool axis (rule § Step 2): an option
      grep cannot see a PACKAGE, so check what this repo already installs and what nixpkgs
      ships. `nh` owning `--elevation-strategy` while already on PATH is the worked example.
      Re-run the grep
      for any that don't; inputs gain options between bumps, so a shim that was justified at
      write time can be obsolete now. Resolve the pinned source, don't read upstream HEAD:
      `src=$(nix eval --raw --impure --expr 'builtins.toString (builtins.getFlake "'"$PWD"'").inputs.nix-darwin.outPath')`
      then `grep -rn "<concept>" "$src/modules/"`.
- [ ] `NH-E-script-not-wsa` — `writeShellApplication` for scripts; shellcheck via that path.
- [ ] `NH-E-etc-hack` — no new `environment.etc` hacks for things nix-darwin models.
- [ ] `NH-E-determinate-drift` — Determinate Nix (darwin): no `nix.enable = true` / no hand-written `nix.custom.conf`. On the NixOS hosts the nixosModule keeps `nix.*` live, so `nix.settings` there is correct, not drift.
- [ ] `NH-E-hand-rolled-systems` — **flake-parts everywhere, including here.** The small supporting flakes that
      remain (any new one — the last existing member, ircc-whatsapp-bot, was
      unwired on 2026-09-12) use flake-parts,
      not hand-rolled `forAll`/`forAllSystems` boilerplate — ADR-001
      (`docs/flake-architecture-strategy-adr.md`). `nix-mcp-gateway` used to be on
      this list and is **archived** (2026-09-12, an unadopted extraction candidate —
      the fleet's own gateway was `modules/shared/mcp.nix`, itself **deleted 2026-10-02**, so
      neither exists now); do not re-add either from memory. A new one scaffolded without it,
      or an old hand-rolled pattern creeping back in via copy-paste, is a finding.
      **`nix-config`'s own engine is no longer the exception.** ADR-001 §2 said
      "do not migrate the core engine"; ADR-002
      (`docs/monoflake-capsule-adr.md`) superseded that and wave 2 did the
      migration, so a surviving `forAllSystems` fold or a new `genAttrs systems`
      in this repo IS hygiene debt now. The engine is `modules/parts/*.nix`,
      one flake-parts module per concern, discovered by `import-tree`.
- [ ] `NH-E-capsule-smuggle` — **capsule boundary.** Anything under `modules/features/<name>/` is a capsule:
      `flake-module.nix` is the only file outside code may import, and no file in
      the directory may hold a `..` path literal — **including one that escapes
      nothing**, like a `checks/` leaf reaching `../module.nix`; the entry file
      passes that DOWN as an argument instead. That is enforced by
      `ast-grep/rules/capsule-must-not-reach-out.yml` + `checks.<system>.capsule-registry`,
      so a violation is a build failure, not a review finding — but a capsule that
      smuggles a value out through `specialArgs`, an overlay, or a runtime-built
      store path is invisible to both gates (ADR-002 §7.6) and IS a finding here.
      Never widen the seam to make red go green; add a typed engine seam
      (`fleet.*` in `modules/parts/`) instead.
- [ ] `NH-E-deprecated-config` — **no deprecated spellings against the PINNED upstream.** A
      config key or component name the pinned package or input marks deprecated still works,
      which is why nothing else catches it: it fails only on the bump that removes the alias.
      Read it from upstream's own output, not from memory: `grep -i deprecat` over each
      declared service's log since the last activation (launchd `StandardErrorPath`;
      `journalctl -u <unit> -b` on NixOS), and over `nix flake check --all-systems --no-build`
      warnings. Confirm the replacement against the pinned package before renaming. Worked
      example (2026-11-04): otelcol-contrib 0.155.0 logs `"otlphttp" alias is deprecated; use
      "otlp_http"` (and `hostmetrics` → `host_metrics`); `otelcol-contrib components` lists
      only the new names.

### F. Mechanical gate — `NH-F-gate` (run on the snapshot in `audit`, after fixes in `fix`)

```bash
git add -A
nix fmt
git add -A   # fmt may rewrite
git status --porcelain '*.nix'   # clean of ?? 
nix flake check --all-systems --no-build   # evaluates BOTH systems; a bare check on the Mac omits aarch64-linux
nix flake check                  # THE suite (builds); or scoped nix eval of affected toplevels
```

If the scope touches what the linux-only checks cover, also run the `nix build --no-link
.#checks.aarch64-linux.{…}` line from [`docs/map/ci.md`](../../../docs/map/ci.md) — it owns
the list.

If `nix` unavailable: `nix-instantiate --parse` on changed `.nix` + state CI-deferred.

### G. Domain doctors (only if scope touched)

| Scope | Command |
|---|---|
| nixpi flash/provision | skill `nixpi-firmware-provision` |

### H. Optional second opinions

- Structural harshness: global **code-review** skill on the diff.
- Behavior check after fix: manually drive the change end-to-end (no dedicated command).
- PR findings only: a manual diff review (no dedicated command).

## Fix policy

| Do | Don't |
|---|---|
| Delete dead code and experiment comments | Drive-by renames across the monorepo |
| Gate host-only agents with `isMacosHost` | Add options "for later" |
| Update runbook + skill together | Leave CLAUDE.md lists stale |
| One logical commit, one PR per change | Silent behavior change without note |

**Breaking host behavior** (e.g. removing an agent): say so in the report; prefer `mkIf` off over surprise removal.

## Report format (always end with this)

The SARIF file is the report; this block only points at it. Every line is read from the file or
from `doctor-report`, never restated by hand.

```markdown
## Hygiene report
- **Mode:** audit | fix · **Subject:** origin/<default> @ <sha>
- **Run:** <published .sarif path> · `doctor-report verdict` → 0 | 2 | 1
- **Diff vs previous:** N new · N persisting · N resolved (`doctor-report diff`)
- **Vacuous rules:** <ruleIds with kind notApplicable>, or none
- **Findings:** (ruleId — findingId — file — action taken or deferred)
- **Verdict:** CLEAN | FINDINGS | FIXED | BLOCKED (why)
```

## Anti-patterns specific to this fleet

Each maps to a rule: 1 → `NH-C-ungated-host-list`, 2 → `NH-X-guest-rotation`,
3 → `NH-X-image-in-flake`, 4 → `NH-X-lock-hand-edit`, 5 → `NH-C-launchd-name`.

1. **A sandbox host inheriting macos login openers / RAG** — hosts stay lean. (The MCP gateway
   used to be the third item here; it was deleted 2026-10-02.)
2. **Guest file-rotation on the shared `~/Downloads`** — host-only (`mv` across
   filesystems = `cp` + `rm`, so a guest rotation destroys host files).
3. **Putting `.utm` / IPSW / disk images in the flake.**
4. **Hand-editing `flake.lock`.**
5. **HM launchd bypassing `launchd-launcher.nix` / without a `nix-*` basename** — BTM phantoms return.

## Compose with existing automation

```
/hygiene [fix] [scope] → this skill (audit by default; fix only when asked)
/eval                → eval only
code-review skill    → structural/PR-diff review (no dedicated /review or /verify command exists)
```
