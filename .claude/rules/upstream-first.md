---
# Scoped per docs/en/memory § Path-specific rules: an unscoped rule loads at
# session launch at CLAUDE.md priority, and this repo already gates CLAUDE.md at
# 40,000 chars — a budget the rules directory bypassed entirely.
# The rule fires when custom Nix is about to be written, so the .nix glob is its
# actual trigger rather than a proxy for one.
paths:
  - "**/*.nix"
---

# Upstream First — Grep the Pinned Option Surface Before Writing Custom Nix

**Before proposing or writing any custom Nix, you MUST first grep the pinned input's own
option surface, and cite the result.** Not "consider whether one exists" — grep, then say
what you found.

This repo's inputs (nix-darwin, home-manager, agenix, deploy-rs, nix-homebrew, …) already
expose thousands of options. Answering from ecosystem memory instead of reading the pinned
source is how a supported one-line option gets reimplemented as a hand-rolled shim.

## When this fires

Any time you are about to reach for one of these:

- `home.file` / `home.activation` / `xdg.configFile` used as a **shim or workaround**
- `system.activationScripts.*`
- a `pkgs.writeShellScriptBin` wrapper whose job is "make tool X see Y"
- a launchd unit, a symlink farm, an `environment.etc` entry
- any shell that sets, exports, patches, or links something the platform already models

Ordinary declarative use of those options is fine. The trigger is using them to **emulate
behaviour a module might already own**.

## The required step

```bash
# Resolve the pinned input's source (the exact rev in flake.lock, not upstream HEAD)
src=$(nix eval --raw --impure --expr \
  'builtins.toString (builtins.getFlake "'"$PWD"'").inputs.nix-darwin.outPath')

grep -rn "<concept>" "$src/modules/"
```

Swap `nix-darwin` for `home-manager`, `agenix`, etc. Grep for the **concept**, not the
option name you hope exists (`envVariables`, `setenv`, `PATH`, `launchd` — several spellings,
because you do not yet know what upstream calls it).

Read the implementation, not just the option declaration: an option can exist and not do what
its name suggests, and the implementation tells you the traps (see the `$HOME`/`$USER`
substitution in `modules/darwin/core.nix` § GUI PATH).

### Step 2 — the TOOL axis, because step 1 structurally cannot see it

**A grep of `modules/` finds options. It can never find a PACKAGE.** If the thing you are
about to write is a CLI or a wrapper rather than a setting, no amount of grepping an input's
option surface will tell you the ecosystem already ships it. Two probes, both instant, run
them before writing a line:

```bash
# 1. Is it ALREADY INSTALLED in this fleet? (the cheapest, and the one that has caught it)
grep -rn "<tool-or-concept>" modules/shared/home.nix hosts/*.nix modules/darwin/*.nix
command -v <tool>

# 2. Does nixpkgs ship something for this concept?
nix search nixpkgs <concept> 2>/dev/null | head -20
```

Probe 1 matters most: this repo installs ~100 packages, and the tool you are reimplementing
is quite likely one of them already. Being on `PATH` is not evidence that it was considered —
it may have been added for a different reason entirely.

If a community tool does own the behaviour, you may still write your own — but say **why**,
on measurement, and name the condition under which yours should be retired. "I did not know
it existed" is not a why.

## The required output

Every answer that proposes custom Nix must contain **one** of these two lines:

- ✅ `upstream option <input>.<option> exists → using it` (with the source line you read), or
- ✅ `grepped <input>/modules for <terms> — no option exists → custom, because <reason>`

…and, when what you are writing is a **CLI or wrapper** rather than a setting, a second line:

- ✅ `no community tool owns this (searched: <terms>)`, or
- ✅ `<tool> owns this → not using it, because <MEASURED reason>; retire this when <condition>`

**An answer proposing custom Nix without one of those lines is incomplete.** Say it out loud
in the answer; it is the artifact that proves the step ran.

## Why a rule and not a preference

The preference is already stated in the global `CLAUDE.md` (§ Reuse over rebuild, ~2x weight)
and in `.claude/skills/nix-hygiene/SKILL.md`. It still failed, because both are **passive**:
they say *prefer* upstream, which presumes you already know the option exists. And
`nix-hygiene` only runs at audit time — after the custom code is written.

This rule is deliberately shaped like [git-purity](git-purity.md): it names a **command** and
a **checkable artifact**, not a value. That is the part that survives contact with a task that
looks too small to warrant research.

## Worked example (2026-09-05)

A GUI app could not find a Home-Manager-installed CLI, because macOS GUI apps inherit
launchd's PATH, not the shell's. Three successive answers proposed custom `home.file` shims
into `~/.local/bin`. One grep settled it:

```bash
grep -rn "setenv\|envVariables" "$src/modules/launchd/" "$src/modules/environment/"
# → modules/launchd/default.nix:125  launchd.user.envVariables
```

nix-darwin has owned this since forever (`modules/system/launchd.nix:14` emits
`launchctl setenv`). The custom shim covered one binary for one app; the upstream option
covers every binary for every GUI app. See `modules/darwin/core.nix` § GUI PATH.

## Worked example (2026-09-15) — the blind spot that made step 2 a rule

`packages/activate.nix` wraps `darwin-rebuild switch` so it re-execs under `sudo`. The step-1
grep was run and was correct: nix-darwin removed sudo self-elevation in its 2025-01-30 root
migration and owns no option that restores it. The wrapper got written.

`nh` (nix-helper) has `--elevation-strategy`. It does exactly this, it is maintained upstream,
**and it was already installed on this Mac and on `PATH`** — `modules/shared/home.nix:1420`.
Step 1 could not have found it: `nh` is a package, so it appears nowhere in any input's
`modules/`. Either probe in step 2 would have surfaced it in seconds.

The wrapper survived review anyway, for a reason that had already been measured and written
down: `home.nix` deliberately sets no `programs.nh.darwinFlake` because nh's progress ticker
repaints ~15x/s with no off switch (`NH_NOM=0` and `NO_COLOR=1` both measured to change
nothing), which is worse than plain `darwin-rebuild` under a pipe. That rejects nh's OUTPUT,
not its elevation — so `activate.nix`'s header now records the comparison and names the
condition under which it should be retired.

The finding is not "the wrapper was wrong". It is that the comparison was owed **before**
writing it, and the rule as written could not produce it.
