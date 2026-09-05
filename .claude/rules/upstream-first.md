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

## The required output

Every answer that proposes custom Nix must contain **one** of these two lines:

- ✅ `upstream option <input>.<option> exists → using it` (with the source line you read), or
- ✅ `grepped <input>/modules for <terms> — no option exists → custom, because <reason>`

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
