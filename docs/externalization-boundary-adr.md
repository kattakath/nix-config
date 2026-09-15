# ADR-003: the externalization boundary — what may leave `nix-config`, and what may never

**Status:** **Decided (design). NOT implemented** — 2026-09-15. Nothing in this ADR has shipped:
there is no `local.agentOverlay` option, no overlay directory, and no behaviour change on any
host. It records a boundary and a rejection, so that the next time the "let a CLI install it at
runtime" idea arrives it is answered from a decision rather than re-litigated.

**Read §10 before trusting §§1-9** — or rather, read that §10 is still **empty**. ADR-002 exists
in two states, design and execution, and its §9 correction record had to overturn four of its own
"ADOPT" rows. This document is currently only the first state. Where execution later disagrees
with a section here, execution wins and §10 records it.

**Deciders:** Ismail Kattakath.

**How this was produced:** an inventory of every global agent resource this fleet installs
(counted from `~/.claude`, `flake.lock` and the live `~/.config/mcp/mcp.json`, not recalled); a
trace of each one back to its source and its *fetch time*; a measured test of the single
constraint the design turns on; and a read of Zhou et al., *Externalization in LLM Agents: A
Unified Review of Memory, Skills, Protocols and Harness Engineering* (arXiv 2604.08224v1), which
supplied the vocabulary and — importantly — **did not** supply the standard.

---

## 1. Decision

1. **`nix-config` is the harness.** It owns orchestration, pinning, secrets, per-client curation,
   permissions, sandboxing, observability and the launchd lifecycle. That list does not move.
2. **Content may be externalized; governance may not.** A skill's markdown can live outside the
   flake. The decision of *which* skill a client sees, *what version*, and *with what credential*
   cannot.
3. **The boundary is the eval/activation line.** This is a hard property of Nix, not a preference
   (§3). Anything that must be *read* from `$HOME` can only be read by an activation script.
4. **The per-surface split is decided by blast radius, not by taste** (§5): plugins are already
   runtime-owned and stay that way; skills MAY be overlaid; **MCP servers stay Nix-owned**.
5. **The seam, if built, is `local.agentOverlay`** — additive-only, read-if-present, evaluated
   never and merged at activation, a silent no-op when the directory is absent (§7).
6. **REJECTED: the full inversion** — "`nix-config` ships only CLIs; every skill, server and
   plugin is installed at runtime into a vendor dotfolder which Nix then consumes." §5 and §8 give
   the reasons. The rejection is of the *inversion*, not of externalization; §6 shows most of the
   idea is already implemented.

## 2. The proposal this answers

Stated fairly, because it is a good idea and three-quarters of it is already true here:

> `nix-config` should contain no skills, MCP servers or plugins. It should expose the agent CLIs
> as Nix-provided apps (`claude`, `qwen`, `gemini`, …). Those CLIs install resources at runtime
> into their own dotfolder (`~/.claude`, `~/.qwen`) following a common standard. At activation,
> if such a folder exists, `nix-config` consumes it and supplies it to its modules; if it does
> not, the clients still work, just without those resources. The folder can optionally be
> version-controlled by the user.

Two halves, and they land differently. The **CLI half is already shipped** (§6). The **"Nix
consumes the folder" half** is where the design work is, and it has one blocking constraint.

## 3. The hard constraint: evaluation cannot read `$HOME`

Measured 2026-09-15, not recalled:

```
$ nix eval --expr 'builtins.readDir /Users/ismail/.claude'
error:
       … while calling the 'readDir' builtin

$ nix eval --impure --expr 'builtins.pathExists /Users/ismail/.claude'
true
```

`--impure` "works" and is not an option: it forfeits flake purity, every Cachix hit, and
`scripts/drv-snapshot.sh`, which is this repo's second test suite and exists precisely to prove a
change did not move what the fleet builds.

So the folder is invisible to **modules**, and visible only to **activation**:

```
┌───────────────────────┐                    
│       flake eval      ├──────────┐         
└───────────┬───────────┘          │         
            │                      │         
            ▼                      ▼         
┌───────────────────────┐ ┌─────────────────┐
│  store only, NO $HOME │ │activation script│
└───────────────────────┘ └────────┬────────┘
                                   │         
                                   │         
┌───────────────────────┐          │         
│     $HOME readable    │◄─────────┘         
└───────────┬───────────┘                    
            │                                
            ▼                                
┌───────────────────────┐                    
│overlay seam lives HERE│                    
└───────────┬───────────┘                    
```

This single line explains why the plugin rail already works the proposed way and the skills and
MCP rails do not: `modules/shared/claude-plugins.nix` is an **activation script** calling
`claude plugin marketplace add`, while `programs.claude-code.skills` and the gateway config are
**evaluated** into store paths. The proposal is not new here — it is the shape one of the three
rails already has.

## 4. Where the vocabulary comes from, and what it does not supply

Zhou et al. (arXiv 2604.08224v1) frame agent capability as **externalization** — relocating
burden from model weights into persistent external structures along three dimensions (**memory**,
**skills**, **protocols**) hosted by a fourth thing that is explicitly *not* a dimension: the
**harness**, the layer supplying orchestration, constraints, observability and feedback.

That is a precise name for what this repo is, and it settles the boundary argument on principle
rather than on habit: the paper assigns **sandboxing, permissions and policy encoding to the
harness**, not to the externalized stores.

Its six harness dimensions, against what this fleet already runs:

| Paper's harness dimension | `nix-config` today |
|---|---|
| Sandboxing & execution isolation | launchd agents; gateway bound to `127.0.0.1`; the patched grok sandbox profile |
| Human oversight & approval gates | `pretooluse-bash-guard.js`, `stop-gate.js`, `superhook` |
| Observability & structured feedback | OTel → `/routing-review`; the superhook incident log |
| Configuration, permissions, policy encoding | `settings.json` as a read-only store symlink |
| Context budget management | `qwen` is handed **11 of 31** gateway servers, deliberately |
| Agent loop & control flow | vendor-owned — not this fleet's |

**Five of six already built.** What the paper — and the ecosystem it surveys — does and does
**not** supply for the proposal (corrected; see §10.2):

| Needed by the proposal | The paper / the ecosystem |
|---|---|
| A skill format the CLI follows | **Exists.** The paper names `SKILL.md` and manifests (§4.3.1) and Claude Code's skill system (§4.3.3); Agent Skills is an adopted open standard, and all 63 pinned skills here already use it |
| A tool-binding protocol | **Exists.** MCP, cited in §4.3.4 as the runtime binding layer; §5.2 surveys agent–tool protocols |
| Registries / marketplaces | **Exist.** §4.5 cites "existing skill marketplaces" (SkillProbe); the Official MCP Registry is what `mcp-scout` already queries |
| A standard *location* for runtime-installed config (`mcp.json`, a shared skills dir) | absent — de-facto only (`~/.agents/`, per-vendor dotfolders) |
| Versioning, dependency pinning | absent |
| Reproducibility, supply-chain trust | absent |
| Governance mechanics | deferred to future work (§8.4) |
| A way to measure any of it | no established metrics (§8.6) |

It does, however, name two of this design's risks under its own *boundary conditions for skills*:
**portability and staleness**, and unsafe composition. Staleness is the unpinned-runtime-clone
problem. Unsafe composition is the failure mode this fleet actually suffered on 2026-09-14.

**Conclusion: the formats are standard; the reproducibility is not.** Skills and MCP servers
already have standard shapes and registries, and this fleet uses both. What has no standard is
the part this ADR turns on — **where a runtime install lands, and how it is pinned and made
reproducible**. Building the overlay means defining *that*, which is the motto-relevant fact: the
reuse weighting is satisfied for the formats and cannot be satisfied for the pinning.

## 5. The per-surface decision, by blast radius

The discriminator is not purity, it is **what happens when the resource is wrong**. Counts below are
**2026-09-15** and they move; `modules/shared/mcp.nix` is the live source, never this table (§10.1).

| Surface | Decision | Failure blast radius |
|---|---|---|
| **Plugins** (9, 3 marketplaces) | **Already runtime-owned — keep** | Claude owns mutable `~/.claude/plugins` anyway; a bad plugin is one bad plugin |
| **Skills** (63) | **MAY be overlaid, additively** | Plain markdown. No build step, no credential, no process. Failure = one missing skill, invisible |
| **MCP servers** (33) | **STAY Nix-owned** | A server that exits at startup **darks the entire gateway** — every client, every server |

The MCP row is not hypothetical. On **2026-09-14** a bumped `mcp-servers-nix` built a broken
`mcp-server-memory`, which took the whole darwin system down; commit `ea4e755` rolled the input
back and `136f14f` moved memory/sequential-thinking/fetch onto nixpkgs builds. The recovery
levers used — **pin the input, override the package** — are exactly the levers a runtime-installed
server does not have.

Three further things the MCP rail would lose by moving:

1. **`passwordCommand` Keychain wiring.** `context7` and `github` read their credential from the
   login Keychain at launch, so no value reaches argv or the store. An overlay JSON cannot express
   that; it would carry a plaintext token in `$HOME` — which § Security of `CLAUDE.md` forbids.
2. **The `public ⊆ hosted` assertion.** `local.mcpGateway.public` is checked against the hosted
   set at eval. An overlay-supplied server is not in that set at eval time, so the assertion
   silently stops covering it.
3. **Per-client curation.** `qwen` gets 11 of 31 servers because a local qwen3-coder degrades when
   handed too many tools. That is a *harness* decision; a flat dotfolder has nowhere to put it.

## 6. Most of the proposal is already implemented — the delta is one decision

| Proposal | Status |
|---|---|
| Expose agent CLIs as Nix-provided apps | **Done** — `claude-code`, `qwen-code`, `grok` |
| Content lives in its own version-controlled repo | **Done** — `github:kattakath/ai`, extracted 2026-09-12 |
| One vendor-neutral file every client reads | **Done** — `~/.config/mcp/mcp.json` + the `:8096` gateway, three clients |
| Runtime install, Nix does not own the state | **Done for plugins** — `claude plugin marketplace add`; mutable `~/.claude/plugins` |
| Read-if-present, silent no-op when absent | **Precedent** — git `includeIf` → `~/.config/git/infin8.inc` |

So the real delta is a single decision applied to skills and MCP: **hash pin, or runtime clone.**
This ADR answers: hash pin for MCP; either for skills, with pinned content remaining the default
and the overlay strictly additive on top.

## 7. The seam, concretely

Only if and when it is built. Additive, never authoritative:

- `local.agentOverlay.dir` — `types.nullOr types.str`, **default `null`**. A runtime `$HOME`-
  relative path, never a Nix source-path literal (§ Code Style, "two axes, never conflate them").
- **Skills:** an activation script symlinks `<dir>/skills/*` into `~/.claude/skills/`. On a name
  collision **the Nix-declared entry wins** and the overlay entry is skipped with a message —
  the harness is authoritative, and a silent shadow of a pinned skill is the exact failure this
  boundary exists to prevent.
- **MCP:** the overlay may contribute servers only by moving gateway-config generation from build
  time to **launchd start** (a wrapper writing merged JSON into `$XDG_STATE_HOME`). Overlay
  entries are `command`/`args`/`env` only: **no `passwordCommand`, no `package`, no `public`.**
  Not built, and not built first.
- **Absent directory ⇒ zero files, zero warnings, byte-identical activation.** That property is
  the whole point and must be regression-tested, not asserted.

## 8. What this gives up — stated, not buried

1. **Half the tree stops being reproducible.** Today a clean Mac rebuilding from `flake.lock`
   reproduces 63 skills byte-for-byte. Overlay content is covered by no `flake.lock`, no Cachix,
   no CI leg and no `drv-snapshot.sh` baseline. "Reproducible fleet" becomes "reproducible core
   plus whatever was in that folder".
2. **Two sources of truth, and a sync problem between them.** The operator already owns
   `github:kattakath/ai`; an overlay adds a second content location with a *different* update
   discipline. Nothing forces them to agree.
3. **A collision surface Nix currently owns outright.** Nix already *writes into* vendor
   dotfolders: `~/.claude/settings.json`, `~/.qwen/settings.json`, `~/.qwen/.env`. Every key a CLI
   might also write needs a declared owner before any of this is safe.
4. **Secrets cannot cross the seam.** Anything needing a credential must stay Nix-side, so the
   overlay is permanently a second-class citizen for exactly the servers that matter most.
5. **No prior art for the part that matters.** Per §4 the formats and registries are standard,
   but there is no pinning or reproducibility convention for runtime-installed agent resources.
   That half would be bespoke — and the motto weights reuse at 2x, so the burden of proof sits on
   this design, not on keeping the status quo.
6. **It makes `~/.claude` load-bearing.** Today it is *derived*: deletable, reconstructed by
   `activate`. After this it holds state that exists nowhere else unless the operator remembered
   to version-control it. That is a new backup obligation, and it is the operator's, not Nix's.

**What it does NOT give up, and the design should not claim credit for it:** the plugin rail's
mutability, `github:kattakath/ai`'s independence, and per-client curation are all already true.

## 9. Open, not decided

1. **Directory name and shape.** `~/.agents/` (vendor-neutral, and the de-facto name already
   used by `vercel-labs/skills`) vs. consuming each vendor's own
   folder. Vendor-neutral is cleaner and has no consumer; per-vendor matches what CLIs actually
   write and has no schema.
2. **Whether to build it at all.** Nothing today is blocked by its absence. The honest trigger is
   a *second* machine or a *second* operator — neither exists.
3. **Whether the skills overlay wants precedence configuration** rather than the fixed
   "Nix wins" rule of §7. Fixed is decided for v1 because it is the safe default, not because
   configurable was measured and rejected.

## 10. Correction record

Nothing here has been *implemented*, so there is no execution record yet. ADR-002's §9 had to
overturn four of its own §3 "ADOPT" rows and one of its core mechanisms, all of which read as
settled before execution began. Treat every measured claim above as measured **at its date**, and
every design claim as untested.

### 10.1 The MCP counts went stale within the hour

This ADR merged as #520. **#519 merged 20 minutes before it**, adding `arxiv-mcp-server` as the
13th base custom stdio launcher — so every MCP count written here was wrong on arrival: hosted
30 → **31**, total 32 → **33**, and Qwen's curated subset 11-of-30 → **11-of-31** (arxiv was
deliberately left out of that subset). Corrected above.

Worth recording rather than quietly fixing, because it is the same failure the CLAUDE.md trim in
that PR had just fixed twice: `docs/repo-map.md` claiming 58 lock nodes against a real 57, and
its ast-grep table claiming three rules against a real five. **A hand-maintained count in prose
drifts on the next merge, not on some distant future date.** The durable form is a pointer to the
source of truth — `modules/shared/mcp.nix` here — with the number as a dated snapshot, which is
how §5 now reads.

### 10.2 §4 misread the paper

§4 claimed the paper "never names" MCP and that registries for skills were "absent", and §8.5
built on that ("no standard, no registry"). Checked against the PDF, both are wrong: §4.3.4 cites
**MCP** as the runtime binding layer, §4.3.1/§4.4 name **`SKILL.md`** and `AGENTS.md`, §4.3.3
names Claude Code's skill system, and §4.5 cites SkillProbe on "existing **skill marketplaces**".
Outside the paper, Agent Skills is an adopted open standard, and this repo's own `mcp-scout`
skill queries the Official MCP Registry.

The **decision survives**, because it never rested on the formats: nothing standardises where a
runtime install lands or how it is pinned, and §5's blast-radius argument is independent of both.
What changed is the stated reason — §4's table and conclusion and §8.5 now say "standard formats,
no reproducibility standard" instead of "no standard". §9.1's `~/.agent/` became `~/.agents/`,
the name already in use. Likely cause, recorded so the next read is careful: the HTML rendering
truncates before §5, and §4.3.4's single MCP citation is easy to miss in a skim.

### 10.3 First application outside agent resources

#522 applied this boundary to the **AWS identity**: `~/.aws/config` left every repo and is owned
by the `aws` CLI, while `nix-bedrock-gate` (governance) stayed in Nix. It is the §7 shape in
miniature — read-if-present at runtime, a silent degrade when absent, and a one-shot
`adoptAwsConfig` migration so leaving Nix cannot delete the content. Still not an implementation
of `local.agentOverlay`; recorded because it is the first measured instance of "content out,
governance in".
