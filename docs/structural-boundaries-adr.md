# ADR-009 — The structural boundaries: what each directory owns, and which half of that is mechanised

**Status:** **DECIDED 2026-10-02 — documentation of an EXISTING shape, not a redesign.** Every
boundary in §§3-5 is the boundary the tree already has; this ADR writes it down and cites the
precedent it follows. One consequence is **proposed and NOT yet done**: the
`modules/shared` → `modules/home` rename (§8). Two warts are **recorded, not fixed** (§9).

**Supersedes nothing.** It is the missing companion to
[ADR-002](monoflake-capsule-adr.md), which *created* the capsule boundary and justified it
against seven deleted repo boundaries, but never stated the surrounding layout the capsules sit
inside. That omission is the finding (§2).

**Read §6 first if you are about to move a file.** It is the only section that distinguishes a
boundary a build will enforce from a boundary only a reader will notice — and an ADR that
restates what a linter already enforces is weaker than one that says which half is which.

---

## 1. The question

Verbatim, the operator's framing:

> *The `modules/` / `packages/` / `modules/features/` boundary is **written down nowhere a
> newcomer would find it**. That is the finding — independent of whether the current shape is
> right.*

Three concrete sub-questions follow from it:

1. What belongs in `modules/darwin/` vs `modules/nixos/` vs `modules/shared/` vs
   `modules/features/` vs `modules/parts/`?
2. Why do packages live in **two** places — top-level `packages/` *and*
   `modules/features/<name>/packages/`? When does a new package go where?
3. What is the rule for a new capsule under `modules/features/`, and what does the capsule
   boundary **forbid**?

## 2. The measured gap — and why it is an ADR, not a README edit

The gap was real and is now **half** closed. Measured 2026-10-02, before #761:

| Where a newcomer looks | What it said about the boundary |
|---|---|
| `README.md` § Repository layout | listed **9 of 29** top-level entries; `packages/` had one clause, `modules/` one clause, no rule for choosing between them |
| `CLAUDE.md` § Navigating the Codebase | one table row per path, each a sentence — and explicitly *"an index, not an encyclopedia"* |
| `docs/repo-map.md` | the long form per path, but organised **by path**, so the *comparison* between two paths exists nowhere |
| `ast-grep/rules/*.yml` headers | the richest source by far — and the last place anyone looks |

#761 (2026-10-02) fixed the **inventory** half: the README layout block now names every
top-level entry, including the ten it had omitted. That answers *"why does this folder exist?"*.

It does not answer *"which of two folders does my new file go in?"* — a **decision** rule, not a
label, and the one thing a per-path index structurally cannot carry. That is this ADR's job, and
it is why this is an ADR: the answer names rejected alternatives and cites upstream precedent,
which is ADR shape, not README shape.

**Honest scoping of the finding.** The boundary was never *undocumented* — two of its four
edges have been mechanically enforced since 2026-09-12 and 2026-09-14 respectively, with
~40-line rationale headers (§6). It was **unassembled**: no single place put the five
directories next to each other.

## 3. The layer map

Five directories under `modules/`, three layers. Composition flows **down** only.

```
┌────────────────────────────┐
│  modules/parts/ — ENGINE   │
│                            ├──────────────┐
│     may reach anywhere     │              │
└──────────────┬─────────────┘              │
               │                            │
               ▼                            ▼
┌────────────────────────────┐ ┌────────────────────────┐
│                            │ │modules/features/<name>/│
│modules/{darwin,nixos,home}/│ │                        │
│                            │ │capsules — entered only │
│        class layer         │ │                        │
│                            │ │  via flake-module.nix  │
└────────────────────────────┘ └────────────────────────┘
```

(Drawn with `modules/home/` — the §8 name. Today's tree says `modules/shared/`.)
Neither arrow has a reverse: the class layer never calls back into the engine, and nothing
outside a capsule names a file inside one but `flake-module.nix`. The capsules and the class
layer do not touch each other at all.

### 3a. `modules/parts/` — the engine

**Owns:** every flake output. `flake.nix` holds inputs and ONE `flake-parts.lib.mkFlake` call;
fourteen files under `modules/parts/` hold everything it produces — `compose.nix` (the
`mkDarwin`/`mkNixos` builders), `checks.nix`, `packages.nix`, `terranix.nix`, `templates.nix`,
`capsules.nix`, and so on, one file per concern, discovered by `import-tree`.

**May reach anywhere.** `../../hosts/nixpi.nix` in `compose.nix` is correct and deliberately
left unflagged by both ast-grep layer rules — each one says so in its own `files:` comment.

**A file belongs here when** it decides *what the flake exports*. A file that decides *what a
host runs* belongs one layer down.

### 3b. `modules/{darwin,nixos,shared}/` — the class layer

Split by **module system**, not by subject matter:

| Directory | Module system | Entry | Live count |
|---|---|---|---|
| `modules/darwin/` | nix-darwin system modules | imported by `mkDarwin` | 10 |
| `modules/nixos/` | NixOS system modules | imported by `mkNixos` | 4 |
| `modules/shared/` | **home-manager** user modules | `home.nix`, imported by BOTH builders | 24 `.nix` + 2 content dirs |

`modules/shared/home.nix` reaches both host classes through one seam —
`mkHomeManagerModule` (`modules/parts/compose.nix:95`), used by `mkNixos` (`:311`) and
`mkDarwin` (`:521`). So "shared" means *shared across host classes*, which is a **scope**, while
its two siblings name a **class**. §8 is the consequence.

**A file belongs here when** it configures a host and is not a whole feature. Platform
divergence inside one of these files is a `lib.mkIf` on `stdenv.hostPlatform`, never a second
copy of the file.

### 3c. `modules/features/<name>/` — the capsules

Seven, each one absorbed satellite flake or (one case) born in-tree:
`cloud-cli`, `cloudflared-connector`, `firmware-secrets`, `keychain-secrets`, `local-rag`,
`media-cli`, `tart-vms`.

**Owns:** one whole feature behind one enable flag, together with its own `packages/`,
`checks/`, `tests/` and `templates/` — everything the deleted satellite repo used to hold.
`flake-module.nix` is the **only** file anything outside the directory may name.

**A directory belongs here when** turning it off should remove *everything* it brought:
`local.mediaCli.enable = false` removes the CLIs, both launchd agents, the Finder Services and
the companion tools together — no orphaned package, no dangling session variable, no stale menu
item to hunt down. That is the test. A single module with one option is **not** a capsule; it is
a file in the class layer.

## 4. Why packages live in two places

They live in two places because there are two *owners*, and the location encodes the owner.

| Location | Owner | Lifetime | Count today |
|---|---|---|---|
| `packages/` | the fleet | independent of any feature flag | 23 `.nix` + 3 dirs |
| `modules/features/<name>/packages/` | that capsule | dies with the capsule | 22 files across **3** of 7 capsules |

**The rule for a new package, in one line:** if deleting exactly one capsule should delete this
package too, it goes in that capsule's `packages/`; otherwise it goes in top-level `packages/`.

Worked both ways:

- `packages/launchd-doctor.nix` reports on **every** launchd unit on the Mac, including units no
  capsule declares. Fleet-owned. Deleting any one capsule leaves it meaningful.
- `modules/features/media-cli/packages/media-queue.nix` is the queue *for* the media CLIs. With
  `local.mediaCli.enable = false` it has nothing to queue. Capsule-owned.

**Why this is not a wart.** It is the one shape the upstream spec names:
numtide/blueprint's folder-structure reference writes the packages contract as a single line,
`packages/<pname>(.nix|/default.nix)` — a flat `.nix` and a directory-with-`default.nix` are
*both* blueprint's `packages/`, not a drift between two styles. This repo uses the flat form 23
times (`packages/acpx.nix`) and the directory form twice (`packages/design-tokens/default.nix`,
`packages/email-signature/default.nix`), which is exactly that line exercised in both halves.
Blueprint has no `features/` key at all, so the per-capsule `packages/` is this repo's own and
rests on ADR-002 §2 instead: a capsule owning its packages is what replaces the satellite repo
that used to own them.

**Where it IS a wart:** `packages/next-right-thing/` and `packages/fleet-mark.svg` — §9a.

## 5. The capsule contract

### What a new capsule MUST do

1. **Live at `modules/features/<name>/`**, kebab-case, one directory.
2. **Name its entry file `flake-module.nix`** — exactly. `flake.nix`'s `import-tree` filter is
   `".*/(parts/[^/]+|features/[^/]+/flake-module)\\.nix"`; any other name is simply never
   imported, and a check that is never imported cannot fail, so CI stays **green** on a
   silently absent feature. That is the worst failure shape available here, and it is why rule
   3 exists.
3. **Self-register**: `capsules = [ "<name>" ];` in its `flake-module.nix`. All seven do.
4. **Export through one of three declared seams**, all declared in
   `modules/parts/capsules.nix`:
   - `perSystem.packages.*` — a finished derivation;
   - `flake.modules.<class>.<name>` (upstream flake-parts' own registry) or `capsuleModules`
     — a module. `capsuleModules` exists because `flake.modules`' element type is
     `types.deferredModule`, whose merge **always** wraps every definition, and for
     home-manager that reorders `home.packages` — measured on `macos`: routing the
     keychain-secrets module through `flake.modules` moved its four CLIs ahead of postgresql in
     `home-manager-path`'s `buildEnv` paths and changed `darwin-system…drv` with byte-identical
     package derivations. `capsuleModules` is `lazyAttrsOf raw`, which passes a definition
     through unchanged;
   - `capsuleSources` — a source **path**, for the one case where an engine module must
     `callPackage` the file against a *host's* own `pkgs` (`tart-vms`' gitlab-tart shims).
     Deliberately small: a capsule reaching for it twice is a sign its consumer belongs inside
     the capsule.

### What the capsule boundary FORBIDS

- **Nothing inside a capsule may name a path outside it.** No `import`, no `readFile`, no
  `callPackage` of `../../anything`. Need the engine? Take it as a module argument, or reach it
  through `inputs.*` / `config.*`. Need a sibling *inside* the capsule? `flake-module.nix`
  passes it **down** (`module = ./module.nix;`) — never up from the leaf. This is why
  `modules/features/cloudflared-connector/checks/module-evaluates.nix` takes a `module`
  argument at all.
- **Nothing outside a capsule may name any file inside it but `flake-module.nix`.**
- **A capsule may not reach a sibling capsule**, by path or otherwise.

### The blind spots, stated rather than implied

The mechanised half covers the **path axis only** (§6). It cannot see a capsule reaching another
through an overlay, through `specialArgs`, or through a store path assembled at runtime —
ADR-002 §7.6 said so and it is still true. Those remain convention.

## 6. Which half is MECHANISED, which half is convention

This is the section to read before moving a file.

| Boundary | Enforced by | Fails how |
|---|---|---|
| A capsule may not reach **out** by path | `ast-grep/rules/capsule-must-not-reach-out.yml` — `kind: path_expression`, `regex: '\.\.'`, `files: modules/features/**`, `severity: error` | **BUILD FAILS** (`checks.<system>.ast-grep`) |
| `modules/shared/` may not cross into `features/`, `parts/`, `hosts/`, `infra/` | `ast-grep/rules/shared-must-not-cross-layers.yml` — same node kind, `regex: '\.\..*/(features\|parts\|hosts\|infra)/'`, `severity: error` | **BUILD FAILS** (same gate) |
| Every `modules/features/*/` directory is actually imported | `checks.<system>.capsule-registry` (`modules/parts/capsules.nix:141`) — `readDir ../features` vs `config.capsules`, both directions | **BUILD FAILS** |
| Each capsule's own module still evaluates | the capsule's own `checks/` — all 7 have one, 10 files total | **BUILD FAILS** |
| No hardcoded `/Users/<name>` in a Nix *value* | `ast-grep/rules/nix-hardcoded-home-path.yml` | **BUILD FAILS** |
| Every `docs/*.md` is named in an index | `checks.<system>.docs-indexed` (`grep -F`, not `lib.hasInfix` — see its own header) | **BUILD FAILS** |
| Every `hosts/*.nix` is named in an index | `checks.<system>.hosts-documented` | **BUILD FAILS** |
| **`modules/parts/` may reach anywhere** | nothing — it is the licensed exception, named in both rules' `files:` comments | n/a |
| **`modules/darwin/` vs `modules/nixos/` vs `modules/shared/`** | **nothing. Convention only.** | a misfiled module is caught by eval only if the option does not exist in that class |
| **`packages/` vs a capsule's `packages/`** | **nothing. Convention only.** | silently fine either way |
| **"is this a capsule or a class-layer module?"** | **nothing. Convention only.** | silently fine either way |
| A capsule reaching out via overlay / `specialArgs` / runtime store path | **nothing.** ADR-002 §7.6 blind spot | silently fine |

**So: the capsule's outer wall and the shared profile's layer crossings are mechanised. Every
boundary in §3b and §4 — the two questions a newcomer actually asks — is convention.** That
asymmetry is deliberate and is the reason this document exists: a convention with no enforcement
needs a *decision* written down, because nothing else will remind anyone.

Two further asymmetries worth naming:

- **`shared-must-not-cross-layers` went in at `severity: error` with zero existing
  violations** — its own header: *"TRUE THE DAY IT LANDED"*, 2026-09-14 — so it fences a layer
  where it already sits rather than
  describing a migration. The same is **not** available for §3b: a `shared`/`darwin`/`nixos`
  misfiling is not expressible as a path regex, because the evidence is the *option namespace a
  file writes into*, which ast-grep cannot resolve.
- **`capsule-must-not-reach-out` is scoped to `modules/features/**`**, which leaves the
  mirror-image breach open: an *engine* or *shared* file naming a path **inside** a capsule is
  not flagged. `capsuleSources` exists precisely so the one real instance did not have to be
  `../features/tart-vms/packages/gitlab-tart.nix` in `modules/shared/home.nix` — a line ast-grep
  would not have caught. The `shared-must-not-cross-layers` rule later closed that hole for
  `shared/` specifically; for `parts/` it is open by design.

## 7. The shape is STANDARD — the precedent, checked at the source

Every row below was verified on 2026-10-02 against the live upstream, not from memory. **Caveat
stated up front:** numtide/blueprint is **not** a pinned input of this flake, so these are cited
*external* precedents, not a grepped option surface. That is a weaker class of evidence than
[upstream-first](../.claude/rules/upstream-first.md) asks for when choosing a mechanism — it is
the right class for justifying a *layout*, which no pinned input can validate.

| This repo | Precedent | Verbatim |
|---|---|---|
| `packages/<name>.nix` **and** `packages/<name>/default.nix` side by side | blueprint `docs/content/getting-started/folder_structure.md`, § `packages/` | **one heading, both forms** — quoted in the block below |
| `modules/` split many ways (`darwin`, `nixos`, `shared`, `parts`, `features`) | same file, § `modules/` | *"Where the type can be any folder name."* — heading quoted below |
| `modules/{darwin,nixos,home}` as the names | same section | the three types it maps to outputs: *"darwin" → `darwinModules`, "home" → `homeModules`, "nixos" → `nixosModules`* |
| one module tree per *class*, home-manager separate | `ryan4yin/nix-config` root tree | top-level `modules/` **and** `home/` as sibling trees; its own `AGENTS.md`: *"`modules/` contains system modules; `home/` contains Home Manager modules"* |
| `templates/default/` | blueprint, § `templates/` | `templates/<name>/` … *"If no name is passed, it will look for the `default` folder."* |
| `claude/` (shipped to `$HOME`) vs `.claude/` (configures sessions here) | `ryan4yin/nix-config` root tree, verified entry-by-entry | `tree agents` **and** `tree .agents` **and** `blob AGENTS.md`, all three at root — letter-for-letter the same three-way split, down to its `AGENTS.md` saying *"Keep repository guidance here; reusable global rules live in `agents/AGENTS.md`"* |
| `sgconfig.yml` at the repo root, rules under `ast-grep/` | the file's own header | *"Paths are relative to THIS file, which is why it must stay at the repo root"* — `ruleDirs: ./ast-grep/rules`. Mechanically required, not a style choice |

The two headings the first two rows point at, verbatim from blueprint's
`docs/content/getting-started/folder_structure.md` — pipes and all, which is why they are quoted
here rather than inside a table cell:

```
packages/   heading:  `package.nix`, `formatter.nix`, `packages/<pname>(.nix|/default.nix)`
modules/    heading:  `modules/<type>/(<name>|<name>.nix)`
```

Two genuinely local inventions, named as such rather than claimed as precedent:

- **`modules/parts/`** — blueprint has no engine key, because blueprint *is* the engine. This
  repo uses flake-parts + `import-tree` directly (ADR-002 decision #2), so the engine is a
  directory. The **dendritic pattern** that `import-tree` was written for goes further still —
  every file a flake-parts module, no central wiring at all — so a multi-way `modules/` split is
  conservative against that precedent, not exotic.
- **`modules/features/`** — the capsule layer. ADR-002 §2 is its whole justification: absorbing
  seven satellite repos deleted the only *mechanical* isolation this fleet had, and the capsule
  boundary plus `capsule-must-not-reach-out.yml` is what replaces it with something that fails a
  build rather than a review.

**Consequence of §7 for this ADR's scope: no migration is proposed.** The layout is
conventional. What was missing was the write-up.

## 8. The one consequence: `modules/shared` → `modules/home`

**Proposed here, performed separately. This rename is this ADR's consequence, not a separate
whim** — it falls directly out of §3b's table, and recording the boundary is what makes it
visible.

**Why.** `shared` names a **scope** (which host classes get it) while both its siblings name a
**class** (which module system consumes it). Blueprint's type key for exactly this tree is
`home`. The strongest evidence is in-repo and already written down: the header of
`ast-grep/rules/shared-must-not-cross-layers.yml` introduces the directory as
*"`modules/shared/` the home-manager profile"* — the linter that fences the layer already calls
it by the class name the directory does not use.

After the rename the §3b table reads `modules/{darwin,nixos,home}`, which is blueprint's own
triple verbatim, and the ast-grep rule's `files:` glob becomes `modules/home/**`.

**What the rename must carry with it** (the rename PR's checklist, not this ADR's work):

- the `files:` glob and the id/message of `shared-must-not-cross-layers.yml`;
- `../shared/home.nix` and `../shared/nix-cache.nix` in `modules/parts/compose.nix` (`:210`,
  `:299`);
- `../shared/nix-ld-libraries.nix` in `modules/nixos/core.nix:133` and
  `../modules/shared/nix-ld-libraries.nix` in `packages/devcontainer-image.nix:98`;
- every prose reference in `CLAUDE.md`, `README.md`, `docs/repo-map.md` and the ast-grep headers;
- **`scripts/drv-snapshot.sh --compare` must show an empty diff.** A pure rename moves code and
  must change nothing the fleet builds; that harness is ADR-002's acceptance test and is the
  only evidence that claim is true.

**And two files should NOT make the trip** — §9b.

## 9. The weakest parts of the current shape

### 9a. `packages/` holds two things that are not packages

Blueprint's contract is `packages/<pname>(.nix|/default.nix)`. Two entries break it:

| Entry | What it actually is, with the evidence |
|---|---|
| `packages/next-right-thing/` | **six shell scripts, no `default.nix`** — not a package, and not a flake output either: zero references in `modules/parts/packages.nix`. It is a *source tree*, read as `scriptDir = ../../packages/next-right-thing;` by `modules/shared/next-right-thing.nix:28`, which assembles the real derivation itself with `runCommand` |
| `packages/fleet-mark.svg` | a bare asset at the directory root, `builtins.readFile`-d by a sibling (`packages/spotlight-launchers.nix:115`) |

This is the **weakest part of the layout**: the one directory whose name asserts a type contains
two entries that fail it, and nothing checks. A reader who infers "everything in `packages/` is a
package" is wrong twice, and `next-right-thing` is the worse of the two because it *looks* like
blueprint's directory form from the outside.

**Not fixed here, deliberately.** Both are small, both are inert, and a fix is a real move
(`sites/`-style content tree, or a `default.nix` wrapper) that would change what the fleet
builds — which belongs in its own PR behind `drv-snapshot.sh`, not inside a documentation ADR.
Recorded with evidence instead of migrated, per the brief.

### 9b. `modules/shared/` holds two files that are not home-manager modules

Measured 2026-10-02: **24 `.nix` files + 2 content directories.** 22 of the 24 are
home-manager (`home.nix` plus the 21 siblings it imports). The other two are not:

| File | What it is, with the evidence | Where it belongs |
|---|---|---|
| `nix-cache.nix` | a **NixOS-only system module**. Its own line 3 says *"NixOS-ONLY module"*, and it is wired into `mkNixos`'s module list only (`modules/parts/compose.nix:299`) — the Mac routes the same cache through `determinateNix.customSettings` instead | belongs in `modules/nixos/` |
| `nix-ld-libraries.nix` | **not a module at all** — `pkgs: with pkgs; [ … ]`, a function, consumed by `modules/nixos/core.nix:133` **and** `packages/devcontainer-image.nix:98` | blueprint's key for this is `lib/`; `ryan4yin/nix-config` likewise has a top-level `lib/` |

So the §8 rename is correct for **22 of 24** files and would actively mislead on two. Those two
should move *as part of* the rename, not after it: `modules/home/nix-cache.nix` would be a
worse name than today's.

The 2 content directories (`wallpaper/` — two PNGs; `chromium-extensions/` — a `.crx` and its
source) are a milder version of §9a: binary content inside a tree named for modules. Left alone;
each sits next to the one module that reads it, which is the argument for keeping them.

### 9c. `checks/` is split three ways and blueprint has one key for it

Flake checks live in `modules/parts/checks.nix` (the fleet's), in
`modules/features/*/checks/` (each capsule's), and — for formatting — in `treefmt.nix`.
Blueprint's spec has a single top-level `checks/`. The split is defensible (a capsule owning its
own checks is the capsule contract, §5) but it means "where do I add a check?" has the same
two-place answer as §4 with no rule written anywhere but here. Recorded, not changed.

## 10. Alternatives considered

| Alternative | Why rejected |
|---|---|
| **Adopt numtide/blueprint itself** | It would replace `modules/parts/` wholesale, and ADR-002 already decided the engine question in favour of flake-parts + `import-tree` after measuring it. Blueprint also has no `features/` key, so all seven capsules would need re-homing — a migration to gain a layout this repo already matches. Rejected on cost, and §7 shows there is no divergence to fix. |
| **Flatten `modules/features/` into the class layer** | Deletes the only mechanical isolation the fleet has (ADR-002 §2) and re-opens exactly what the satellite absorption was designed to keep: one enable flag removing a whole feature with no orphans. |
| **Merge `packages/` into one tree** | Either the fleet tree grows capsule-lifetime packages that outlive their capsule, or capsules lose the self-containment §5 defines. The two-place split *is* the ownership statement. |
| **Mechanise §3b with an ast-grep rule** | Not expressible. The evidence for "this is a home-manager module" is the option namespace it writes into, which ast-grep cannot resolve — it matches syntax, not scopes. A convention honestly labelled as convention (§6) beats a rule that matches the wrong thing. |
| **Put all of this in `README.md`** | #761 put the *inventory* there, which is README shape. A decision rule that names rejected alternatives and cites precedent is ADR shape; and `CLAUDE.md`'s own header forbids the encyclopedia form (it sits at 39,746 of 40,000 bytes). |
| **Perform the §8 rename in this PR** | A rename must be provable as "moved code, changed no build" by `scripts/drv-snapshot.sh --compare`. Mixing that proof into a docs-only PR makes both harder to review. |

## 11. Decision

1. **The layer map in §3 is the boundary.** Engine → class layer → capsules, downward only.
2. **A new package's location is decided by ownership**, §4's one-line rule: dies with one
   capsule → that capsule's `packages/`; otherwise `packages/`.
3. **A new capsule follows §5's four MUSTs** and is bound by §5's three forbids.
4. **The shape is standard and no migration follows from this ADR** (§7).
5. **`modules/shared` → `modules/home` is adopted as this ADR's consequence**, to be performed
   in its own PR with §8's checklist and an empty `drv-snapshot.sh --compare` diff, carrying
   §9b's two files to `modules/nixos/` and a `lib/`-shaped home at the same time.
6. **§9's warts are recorded, not fixed.** Each is one PR behind the drv-snapshot harness.

## 12. What would reopen this

- **A second host class** (another `nixosConfigurations` consumer, `system-manager`,
  `nix-on-droid`) — §3b's table grows a row and blueprint's "any folder name" clause is what
  licenses it.
- **An eighth capsule that needs a fourth export seam.** Three is already one more than
  flake-parts offers; a fourth is evidence the capsule/class-layer line in §3c is drawn wrong.
- **A capsule breach through a blind spot** — an overlay, `specialArgs`, or a runtime store path
  (§5). That would be the first measured failure of the convention-only half of §6 and would
  justify spending a real mechanism on it.
- **blueprint becoming a pinned input**, which would upgrade §7 from cited precedent to a
  grepped option surface and make alternative 1 in §10 cheap rather than costly.
