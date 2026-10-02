# Repo map — the full fleet architecture

The detail behind [`CLAUDE.md`](../CLAUDE.md) § Overview and § Navigating the Codebase.
`CLAUDE.md` stays a scannable index (one line per path); this file holds the *why* and the
per-path specifics. **Update both together** — a path that changes shape here needs its
one-liner in `CLAUDE.md` refreshed too.

Two sibling docs carry the surfaces that outgrew this map:
[`mcp-gateway.md`](mcp-gateway.md) (**RETIRED 2026-10-02** — history of the MCP gateway, plus the
lane rules and spawn-test measurements that outlived it) and
[`secrets-and-keychain.md`](secrets-and-keychain.md) (agenix + Keychain).

> **MCP, 2026-10-02 — THE GATEWAY AND ITS PORTAL ARE GONE.** Read this before acting on any MCP
> sentence anywhere in this repo. There is no shared proxy, nothing on `127.0.0.1:8097`, no
> `mcp.kattakath.com` portal (that hostname now answers **403**), and no
> `modules/shared/mcp.nix`. **Every MCP server now comes from an enabled plugin's own
> `.mcp.json`, spawned per session, nothing shared** — see § MCP after the gateway for the
> replacement and for what the teardown measured.

## Contents

**Eleven per-domain files under [`map/`](map/), one index here.** This file was a single
298,762-byte document until 2026-10-02; the prose was MOVED, not rewritten, so every section
below reads exactly as it did — only its file changed, and each moved `###` became a `##`.
**`modules/` was by far the largest**, which is why its four sub-sections live in three
separate files rather than one.

Deliberately no line numbers or byte shares: these files are edited often enough that any such
figure would be wrong before it was useful. Hand-maintained on purpose too — a generated table
of contents rots silently and adds a second thing to keep in sync, which is the opposite of
what `CLAUDE.md` § Documentation is for. **If you add a section, add its line here**; if you
add a FILE under `map/`, `checks.<system>.claude-md-budget` fails until that file has a byte
ceiling of its own, so the budget table is not a thing you can forget.

| File | What it holds |
|---|---|
| [The fleet](#the-fleet) | The four targets in one list, below. **Start here.** |
| [`map/entry-points.md`](map/entry-points.md) | The root files: `flake.nix` · `flake.lock` · `treefmt.nix` · `sgconfig.yml` + `ast-grep/` · `deploy.nodes` (deploy-rs magic rollback) · devShell · `secrets/secrets.nix` |
| [`map/hosts.md`](map/hosts.md) | `hosts/` per-host entry profiles, including the two identity-free `generic-*` ones the templates build on — **plus building `aarch64-linux` on the Mac and deploying `nixpi`**: the native Linux builder and its two traps, and what magic rollback actually buys. **Read before any `nixpi` deploy.** |
| [`map/modules-home.md`](map/modules-home.md) | `modules/home/` — the Home Manager profile on every host — **and the Home-Manager modules that are NOT in it.** The largest of these files. |
| [`map/modules-darwin.md`](map/modules-darwin.md) | `modules/darwin/` — macOS system scope. |
| [`map/modules-nixos.md`](map/modules-nixos.md) | `modules/nixos/` — `nixpi` and `nixvm` system scope — the NixOS modules **not** in it, and web serving on `nixpi`. |
| [`map/engine.md`](map/engine.md) | `modules/parts/` (the flake engine) · `modules/features/` (the seven capsules — read the mechanical boundary and the only-entry/three-seams sections before touching any) · `modules/_lib/` (shared **data**, not modules). |
| [`map/packages.md`](map/packages.md) | `packages/` — flake apps and packages, including `activate` and the `nixpi-*` provisioning CLIs — plus the record of why there is no `userscripts/` tree to look for. |
| [`map/infra.md`](map/infra.md) | `infra/` — the five terranix stacks (zones + DNS, `access-org`, `gcp/foundation`, `gcp/budget`, `nixpi-tunnel`) and the `mcp-public` teardown — plus the Cachix binary cache. |
| [`map/claude.md`](map/claude.md) | Claude Code surface. **Read § MCP after the gateway first — it supersedes every older MCP sentence.** Then `claude/` (the GLOBAL context), `.claude/{commands,rules,hooks,skills}/`, global skills, the operator's marketplace, project memory. |
| [`map/ci.md`](map/ci.md) | CI, release, publishing — the hosted legs and `warm-nixpi-cache.yml`, the workflow that keeps the Pi from ever building. |
| [`map/docs-index.md`](map/docs-index.md) | **Every `docs/*.md`, annotated.** The place to look when you want a document and not an architecture. |

## The fleet

All-in-one Nix mono-repo managing a fully declarative **aarch64-only** fleet:

- **`macos`** (aarch64-darwin) — macOS/nix-darwin, the sole client Mac. No remote/incoming
  traffic; it is the SSH *client*, reaching `nixpi` via `cloudflared access ssh` over the
  tunnel, and builds `aarch64-linux` locally on Determinate's native Linux builder.
- **`nixpi`** (aarch64-linux) — NixOS Raspberry Pi 4, the **LIVE server**: static-key SSH
  over a Cloudflare Tunnel connector + Caddy, serving its real sites directly
  (`config.fleet.hostedSites`, `modules/parts/identity.nix` — **one** today, `snoringirl.com`).
- **`nixvm`** (aarch64-linux) — a disposable NixOS dev VM materialised **only** as
  `nix run .#nixvm` (a build-vm XFCE desktop — no installed VM, no builder, no runner). Its
  Nix *store* is rebuilt per boot; its *root* disk is a qcow2 that **PERSISTS** until deleted.
- A matching **Devcontainer** image.

(The `macvm` Tart guest was removed 2026-09-05 — re-add path + what survives in the
in-tree `tart-vms` capsule: [`macvm-readd-runbook.md`](macvm-readd-runbook.md).)

Single source of truth; platform divergence lives in `modules/`, never in ad-hoc shell.

## `modules/` — reusable modules split by platform

Platform branching lives **here** behind `lib.mkIf`, not duplicated across hosts.

Two subtrees are **not** platform splits and are governed by ADR-002
([`monoflake-capsule-adr.md`](monoflake-capsule-adr.md)) rather than by the rule above. Both get
their own top-level section below:

- **`modules/parts/`** — the FLAKE ENGINE. It **may reach anywhere** in the tree.
  → [§ `modules/parts/`](map/engine.md#modulesparts--the-flake-engine)
- **`modules/features/<name>/`** — the seven CAPSULES (the six absorbed satellite flakes that
  survive — `vast-provision` was removed 2026-09-12 — plus `cloud-cli`, born in-tree). A capsule
  is entered **only** through its `flake-module.nix` and **may not reach outside its own
  directory**. → [§ `modules/features/`](map/engine.md#modulesfeatures--the-seven-capsules)

