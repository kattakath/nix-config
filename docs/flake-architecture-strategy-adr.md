# ADR: flake architecture strategy across nix-config and its supporting flakes

**Status**: Partially implemented — 2026-08-20 (decided), migrations #2/#3 complete
same day; `flake.schemas` (#1) and the core-engine/dendritic re-evaluation (#4)
still open.
**Deciders**: Ismail Kattakath

## Context

The fleet is no longer just `nix-config`. It's now `nix-config` (public engine) plus a
growing set of independently-extracted, independently-published supporting flakes —
`nix-firmware-secrets`, `vast-provision`, `nix-local-rag`, `nix-keychain-secrets`, and
most recently `ircc-whatsapp-bot` — each following the same extraction pattern: pull a
self-contained concern out of `nix-config`, publish it as its own repo, consume it back
via a `.follows`-composed flake input. This has worked (four successful extractions),
but every one of these repos currently hand-rolls its own `forAllSystems`/systems-list
boilerplate independently, and none of them use a flake framework.

The question: as this set of supporting flakes keeps growing, is there an
official/community-standard pattern (`flake-parts`, `flake-utils`, the "dendritic
pattern", or something else) that would materially improve modularity, reusability,
idempotency, shareability, and maintainability — worth adopting deliberately rather than
continuing to hand-roll each new repo — and if so, where does it apply: the supporting
flakes, `nix-config` itself, both, or neither?

This was researched, not assumed — see [Sources](#sources). Full discussion in the
session that produced this ADR.

## Decision

**Tiered, not all-or-nothing.**

1. **Adopt [flake-parts](https://flake.parts/) for new and existing small supporting
   flakes** (`nix-local-rag`, `nix-firmware-secrets`, `vast-provision`,
   `ircc-whatsapp-bot`, `nix-keychain-secrets`). This is precisely the shape flake-parts
   is for — small, few-purpose flakes each currently duplicating the same
   `forAllSystems` boilerplate — and its module-system-powered output type-checking
   would have caught real mistakes made in this fleet this week (e.g.
   `ircc-whatsapp-bot`'s `meta.license = lib.licenses.unfree` eval-time gate, discovered
   only by a failed build, not by any earlier check).

2. **Do not migrate `nix-config`'s core engine** (`forAllSystems`, `lib.mkDarwin`,
   `lib.mkNixos`, `lib.mkHomeManagerModule`) to flake-parts or the dendritic pattern.
   At today's scale (2 systems, ~3 real hosts, each already cleanly separated by
   `lib.mkIf`), the documented practitioner guidance is explicit: *"use flake-parts if
   you plan to pull pieces of your flake into reusable modules, otherwise it's likely
   unnecessary."* `nix-config`'s actual reusability need has been **across repos**, not
   within one `flake.nix` — and that's already solved, four times over, by the
   extraction pattern. A flake-parts (or dendritic) rewrite of the core engine would be
   high blast-radius against a repo whose `CLAUDE.md` documents a lot of hard-won,
   host-specific operational knowledge, for a problem this fleet does not currently have.

3. **Adopt [Determinate flake-schemas](https://docs.determinate.systems/flakehub/concepts/flake-schemas/)**
   fleet-wide, independent of the above. Zero restructuring, additive only, and directly
   relevant since every host in this fleet already runs Determinate Nix. It teaches
   `nix flake show`/`nix flake check` to render custom output types (`homeManagerModules`,
   etc.) instead of leaving them opaque — real discoverability value for anyone browsing
   these repos, private or eventually public.

4. **Do not adopt the [dendritic pattern](https://discourse.nixos.org/t/the-dendritic-pattern/61271)
   now.** It solves a different, larger-scale problem (many hosts, heavy cross-cutting
   per-host feature toggling, `specialArgs`-threading pain) than this fleet has today,
   and the pattern itself was recently "decoupled from flakes and flake-parts" — a sign
   the ecosystem around it is still settling. Revisit if/when host count or per-host
   toggle duplication actually becomes painful.

5. **`flake-utils` stays rejected**, which was already true before this ADR — `nix-config`
   never adopted it, correctly per the current official NixOS Wiki guidance ("Using
   flake-utils is not recommended; if you want to use a flake framework, use Flake Parts
   instead").

## Alternatives considered

| Option | Verdict | Why |
|---|---|---|
| Full flake-parts rewrite of everything (core + supporting) | Rejected | Core engine gets no proportional benefit for the risk; see Decision §2 |
| Dendritic pattern everywhere | Deferred | Solves a scale problem this fleet doesn't have yet; still maturing |
| `snowfall-lib` / `std` (divnix) | Not deeply evaluated | Similar territory to flake-parts/dendritic; revisit only if flake-parts itself proves insufficient |
| Keep hand-rolling every new supporting flake | Rejected | The duplicated `forAllSystems` boilerplate is already a real, visible cost across 5+ repos and growing with each new extraction |
| `flake-utils` | Rejected (reaffirmed) | Superseded by flake-parts per official guidance; already correctly avoided |

## Consequences

**What changes:**
- New supporting flakes are scaffolded with flake-parts from day one.
- Existing supporting flakes (`nix-local-rag`, `nix-firmware-secrets`, `vast-provision`,
  `ircc-whatsapp-bot`, `nix-keychain-secrets`) get migrated opportunistically — not a
  single big-bang project, since each is small and independently versioned, matching
  how they were extracted in the first place.
- `flake.schemas` gets added to each repo (supporting flakes and `nix-config` itself) as
  a low-effort pass.

**What doesn't change:**
- `nix-config`'s `flake.nix`, `lib.mkDarwin`/`lib.mkNixos`/`lib.mkHomeManagerModule`,
  and the `forAllSystems` helper stay exactly as they are.
- The extraction-and-`.follows`-compose contract (`docs/private-home-modules.md`) stays
  the primary cross-repo modularity mechanism — flake-parts changes each repo's
  *internals*, not the *contract* between repos.
- No change to any currently-running service or host activation as a direct result of
  this ADR — this is a structural/authoring improvement, not a runtime one.

**New risk surface, and mitigation:**
- Migrating a supporting flake to flake-parts touches its `flake.nix` shape (inputs,
  `perSystem`, module structure) — each migration should go through the same
  eval-then-activate verification discipline already used for `ircc-whatsapp-bot`
  (`nix eval` sanity + a real build before any consumer's lock file gets bumped), not a
  blind `nix flake update` across the fleet.
- `.follows` chaining (needed to avoid the diamond-dependency conflict already hit once
  this week between `ircc-whatsapp-bot`'s `nix-local-rag` input and `nix-config`'s own
  `local-rag` input) gets *more* important, not less, as more repos compose each other —
  worth a standing check before any lock-file bump that pulls in a new transitive input.

## Backlog items (in suggested order)

1. ⬜ **Open.** Add `flake.schemas` to `nix-config`, `nix-local-rag`,
   `nix-firmware-secrets`, `vast-provision`, `ircc-whatsapp-bot`,
   `nix-keychain-secrets` — cheap, additive. Not started despite being listed first;
   #2/#3 were done ahead of it since they were the higher-value, explicitly-requested
   work at the time.
2. ✅ **Done** (2026-08-20). `nix-local-rag` migrated to flake-parts —
   [PR #1](https://github.com/kattakath/nix-local-rag/pull/1). Consumer proof
   against `nix-config`'s real `darwinConfigurations.macos` came back byte-identical.
3. ✅ **Done** (2026-08-20), same day as #2. `nix-firmware-secrets`
   ([PR #2](https://github.com/kattakath/nix-firmware-secrets/pull/2)),
   `vast-provision` ([PR #3](https://github.com/kattakath/nix-vast-provision/pull/3)),
   `ircc-whatsapp-bot` (merged directly to `main` — no CI/PR convention on that repo
   yet), and `nix-keychain-secrets`
   ([PR #2](https://github.com/kattakath/nix-keychain-secrets/pull/2)) — all
   migrated, one at a time, each independently verified (real CI where it exists,
   `nix flake check -L`, a native build via Determinate's native Linux builder for at
   least one non-macOS system per repo, and a consumer-side proof against
   `nix-config` and/or `nix-personal`). `nix-config`'s own inputs for all five were
   deliberately left pinned at their pre-migration revisions — bumping them is a
   separate follow-up, not implied by "migrated."
4. ⬜ **Open, no timeline.** Re-evaluate this ADR's §2 and §4 (core engine, dendritic)
   once the fleet's host count or supporting-flake count roughly doubles, or if
   `nix-config`'s `forAllSystems`/builder functions start showing real duplication
   pain of their own.

## Sources

- [Flake Utils — NixOS Wiki](https://wiki.nixos.org/wiki/Flake_Utils)
- [Flake Parts — NixOS Wiki](https://wiki.nixos.org/wiki/Flake_Parts)
- [flake.parts introduction](https://flake.parts/)
- [Nix flake-parts, flake-utils or neither? — mccurdyc.dev](https://www.mccurdyc.dev/posts/2026/02/nix-flake-parts-flake-utils-or-neither/)
- [Why you don't need flake-utils — ayats.org](https://ayats.org/blog/no-flake-utils)
- [The dendritic pattern — NixOS Discourse](https://discourse.nixos.org/t/the-dendritic-pattern/61271)
- [Flake schemas — Determinate Systems docs](https://docs.determinate.systems/flakehub/concepts/flake-schemas/)
- [DeterminateSystems/flake-schemas](https://github.com/DeterminateSystems/flake-schemas)
- [docs/private-home-modules.md](private-home-modules.md) — the existing cross-repo
  composition contract this ADR builds on, not replaces
