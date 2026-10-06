---
name: acpx-pnpm12-fetchdeps-break
description: acpx-pnpm-deps fails after #809 because nixpkgs' default pnpm went 11.25.0 -> 12.3.4 and pnpm 12's new links/ store farm feeds JSONC files to the fetchDeps fixupPhase jq loop
metadata:
  type: project
---

`activate` for `#macos` broke at `acpx-pnpm-deps.drv` (builder exit 5) starting with
commit `0ae5732` / PR #809 ("chore: bump flake inputs", 2026-10-06). The failure is
**not** in acpx and **not** in `packages/acpx.nix` — it is a nixpkgs `fetchPnpmDeps`
regression triggered by the pnpm major bump.

**Why:** #809 moved the root `nixpkgs` input (DeterminateSystems/nixpkgs-weekly)
`ef34387ddd751e1ab8857adf4676492d32eb24ec` -> `44a91898084f46797b5fac650c7e8c9ac38c43d4`.
That carried the default `pnpm` attribute from **11.25.0** to **12.3.4** (measured by
building `#pnpm` from both pins). pnpm 12 replaced the store's `projects/` directory with
`links/<pkg>/<ver>/<hash>/node_modules/<pkg>/` — an *unpacked* hardlink farm. Measured
side by side on a one-package probe:

| pnpm | store children | `*.json` under store |
|---|---|---|
| 11.25.0 | `files index.db projects` | **0** |
| 12.3.4 | `files index.db links` | **4** (incl. `tsdoc-metadata.json`) |

nixpkgs' fetchDeps `fixupPhase` runs
`for f in $(find $storePath -name "*.json"); do jq --sort-keys "del(.. | .checkedAt?)" $f | sponge $f; done`
and prunes only `{v3,v10,v11}/{tmp,projects}` — never `links/`. So it now jq-parses every
JSON-ish file the 567 packages ship. **17 of 769 are JSONC, not JSON.** The first one in
`find` order aborts the phase with jq exit 5:
`@tybys/wasm-util/dist/tsdoc-metadata.json`, whose first two lines are `//` comments ->
`jq: parse error: Invalid numeric literal at line 1, column 3`. The rest are
`tsconfig.json` files with `/* */` and `//` comments (es-errors, gopd, hasown, rxjs, ...).

**Upstream, measured 2026-10-06 via `gh` against NixOS/nixpkgs:**

| PR | State | Shape |
|---|---|---|
| **#565315** `fetchPnpmDeps: add fetcherVersion 5` | **OPEN**, not merged (opened 2026-09-21, 1 maintainer comment, no approvals) | Sets `npm_config_virtual_store_dir` / `..._global_virtual_store_dir` to a `mktemp -d` **before** install, so `v11/links/` materializes OUTSIDE the archived store; `pnpmConfigHook` rebuilds it offline at use-time. `fetcherVersion = 4` stays supported. Ships regression test `pkgs/test/pnpm/pnpm_12_v5`. **This WOULD fix this build** — it removes `links/` from the jq loop's reach entirely. |
| **#501300** `exclude links/ from checkedAt cleanup` | **CLOSED unmerged** (2026-05-29) | The narrow fix (scope `find` to `*/index/*`). Maintainer `Scrumplex` rejected it: `v10/.../integrity-not-built.json` also carries `checkedAt` *outside* `links/`, so a bare exclusion is not general. Superseded by #565315. |
| #537020 `xmcl: init` | CLOSED | Casualty, not a fix — author packaged a prebuilt binary instead. |

No nixpkgs **issue** tracks this; all three items are PRs. Upstream's own repro (`Qusic`)
is `@pnpm/npm-conf@3.0.3/lib/tsconfig.make-out.json` — same mechanism, different jq message
(`Expected another key-value pair`), because the message depends on the JSONC shape.

**Nuance on the trigger — do not overstate it.** `links/` as a pnpm *feature* predates 12:
global virtual store was experimental in **pnpm 10.12**, default for *global installs* in
**pnpm 11.0** (which also documents `{storeDir}/links/` for config dependencies). pnpm 12.0's
release notes mention no store-layout change. What the local A/B proves is narrower and is
what matters here: for **this project, this lockfile, this command**, 11.25.0 produced
`projects/` + 0 `*.json` and 12.3.4 produced `links/` + 769 `*.json`. So the correct claim is
"the default pnpm reaching a version where the virtual store is on by default for a regular
project install", not "pnpm 12 invented links/".

acpx does **not** set `virtualStoreType: global` — `pnpm-workspace.yaml` has only
`minimumReleaseAge`/`allowBuilds`/`overrides`, `.npmrc` only registry lines. Upstream
`package.json` declares `packageManager: pnpm@11.27.1`, now 1 major behind nixpkgs.

The loop text is **not** an assumption: it was read verbatim out of this pinned nixpkgs'
own derivation `env.fixupPhase`, byte-identical to the quote in #565315's context.

**How to apply:** do not chase `packages/acpx.nix`'s version or the acpx source. Any fix
must address the pnpm-12 store shape. Also note `pnpmDeps.hash`
(`sha256-IwhKoL4W0ukJ3TBjLZm6fcqd8+0rx4FvVfVcJ0zVkI0=`) was computed against a **pnpm 11**
store and is stale regardless — a fixed fixupPhase will still produce a different tarball.
Related: `nodejs_22` stays pinned for an unrelated reason (fleet default is 20.x, acpx
engines need >=22.13.0).

**Reproduction / measurement recipe that worked** (keep it — the sandbox is where the
evidence lives):
`nix build --keep-failed --no-link <drv>^out`, then the kept dir under
`/nix/var/nix/builds/` holds the pnpm store at `tmp.XXXX/v11`. Re-run the exact jq loop
over it to name the offending file. The file the real build died on is the one left
**0 bytes** — `jq | sponge` truncates it before the pipeline's non-zero exit aborts the
phase.

See [[worktree-guard-refuses-runtime-paths]].

## RESOLVED 2026-10-06 (commit `e3f4add`)

`packages/acpx.nix` now wraps the `fetchPnpmDeps` call in `.overrideAttrs` adding
`preFixup = "rm -rf $storePath/{v3,v10,v11}/links"`. `preFixup` is the right slot because
the pinned fetchDeps' custom `fixupPhase` string *opens* with `runHook preFixup` (read out
of the drv's own `env.fixupPhase`), so the prune lands before the jq loop.

New hash: `sha256-NS2ZPj+Aj1OIP4+Ekcphd7Yy1Q1s1zvU3vILnYPOGAc=`
(was `sha256-IwhKoL4W0ukJ3TBjLZm6fcqd8+0rx4FvVfVcJ0zVkI0=`, a pnpm-11 store).

**Proven, not assumed: dropping `links/` from the archive does NOT break use-time
install.** `nix build .#darwinConfigurations.macos.system` built `acpx-0.19.3.drv`
green — `pnpmConfigHook` + `pnpm install --offline` rebuild the hardlink farm from
`files/` + `index.db`. This was the only real risk in the approach.

**Rejected alternatives, do not retry:**
- a nixpkgs overlay patching `fetch-pnpm-deps` — operator called it fleet-wide drift for
  one package's bug.
- making the jq loop tolerant (lax jq / shadowed `jq` wrapper) — a laxer loop still
  *rewrites* 769 dependency files, where the prune makes the loop a no-op. Strictly less
  blast radius for the same outcome.

Retire the override when `fetcherVersion = 5` reaches the pinned nixpkgs.
