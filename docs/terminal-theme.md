# The terminal theme, held in one place

Every terminal-ish surface on this fleet takes its colours and type from **one**
module: [`modules/shared/terminal-theme.nix`](../modules/shared/terminal-theme.nix),
which declares `local.terminalTheme` and publishes a derived view at
`config.lib.terminalTheme`. Nothing else states a hex value.

This page is the *why*. The measured derivation of each colour lives beside the
values in the module itself; what follows is the architecture, the coverage
ceiling, and the two off-the-shelf providers that were evaluated and rejected.

## Shape

```
local.terminalTheme          16 hex + background/foreground/cursor + font face & sizes
        │
        ▼
config.lib.terminalTheme     byName · ghosttyPalette · toRgb16
        │
        ├── programs.ghostty.themes.fleet          16/16 slots
        ├── programs.vscode … colorCustomizations  16/16 slots
        └── Terminal.app osascript                  4/16 — OS ceiling
```

The provider is **pure options plus derivations**. No packages, no activation, no
platform gate — so it evaluates on `aarch64-linux` exactly as on
`aarch64-darwin`, and every *consumer* keeps its own gate (`isMacosHost` for
Ghostty, `isDarwin` for VS Code and Terminal.app).

The derived surface hangs off `config.lib`, which is home-manager's own
documented extension point for this (pinned `modules/misc/lib.nix:5`) — the same
seam `config.lib.base16` and `config.lib.stylix` use.

## Coverage, per surface

| Surface | Slots | How it is fed | Gate |
|---|---|---|---|
| **Ghostty** | 16/16 + bg/fg/cursor | `programs.ghostty.themes.fleet` → `$XDG_CONFIG_HOME/ghostty/themes/fleet`, selected by `settings.theme = "fleet"` | `isMacosHost` |
| **VS Code** integrated terminal | 16/16 + bg/fg/cursor | `workbench.colorCustomizations` (`terminal.ansi*`, `terminalCursor.foreground`) | `isDarwin` |
| **Terminal.app** | **4/16** | `osascript` on `settings set "Pro"` | `isDarwin` |
| **Starship** | n/a — follows the live ring | named colours, deliberately | every host |

### Why Terminal.app is 4 of 16 — and always will be

Terminal's scripting dictionary exposes exactly four writable colours on the
`settings set` class, plus the two type properties:

| Property | `sdef` line |
|---|---|
| `cursor color` | :368 |
| `background color` | :371 |
| `normal text color` | :374 |
| `bold text color` | :377 |
| `font name` | :380 |
| `font size` | :383 |

```
sdef /System/Applications/Utilities/Terminal.app | grep -ci ansi
0
```

**There is no ANSI ring in the API.** The ring exists only inside the
NSKeyedArchiver'd `NSColor` blobs a vendored `.terminal` profile carries, and
that is the approach #319 deliberately dropped. So 4/16 is macOS's ceiling, not
a gap in this design.

Two consequences worth knowing:

- **Values must be 16-bit RGB lists**, not hex — hence `toRgb16`. The scale
  factor is **257**, not 256, confirmed against a live read-back of stock `Pro`
  (`{62099, 62099, 62099}` for its ~`#F2F2F2` text).
- **`font name` wants the PostScript name** (`UbuntuMonoNF`), not the display
  family. Getting it wrong is *silent*: Terminal keeps its previous font, logs
  nothing, returns no error.

Colours are written to `Pro` only, while type size is written to every profile.
`Pro` is the profile this repo already forces as default and startup; painting
the aubergine ground onto Basic/Homebrew/Novel would destroy them for no gain.
Type size is ergonomics, so it stays ungated.

`bold text color` is set to the **same** value as `normal text color`. Stock
`Pro` makes bold brighter than normal (`#FFFFFF` over ~`#F2F2F2`), but this
palette's foreground *is* `#FFFFFF` — there is nothing brighter. Reaching for
`brightWhite` (`#EEEEEC`) is the obvious-looking move and is **wrong**: it would
render bold *dimmer* than normal text.

This step writes **unversioned user state**. `home-manager rollback` does not
revert `com.apple.Terminal`.

## What is deliberately NOT centralized

| Surface | Why it stays alone |
|---|---|
| **Starship** | It uses named colours (`blue`, `purple`, `bright-black`), which resolve against whatever ring the *live* terminal has. It is therefore already palette-following on `macos`, `nixpi`, `nixvm` **and** inside the devcontainer, where no provider runs. Pinning hex would be a **regression**. |
| **VS Code editor theme** | `workbench.colorTheme` is an *editor* theme; `colorCustomizations` overlays it cleanly. Different concern. |
| **`statusBarItem.*`** | Remote-window chrome. Shares nothing with the ANSI ring. |
| **VS Code font fallback chain** | `'Ubuntu Mono', monospace` is a VS Code-only concern the provider has no opinion about. Only the face name and size are derived. |
| **`nixpi` / devcontainer / `nixvm`** | `nixpi` is headless — no emulator to theme. The devcontainer references tokens, not literals, so it inherits transitively. `nixvm`'s `xfce4-terminal` exists only under `nix run .#nixvm`. |
| **`\033[1;3Xm` escapes** in `bootstrap.sh`, `key-recovery.nix` | Palette followers by construction. |

## Why not stylix, and why not base16.nix

Both were evaluated against the real data before any custom Nix was written.

**[stylix](https://github.com/nix-community/stylix) is the community-common
answer, and it silently breaks this palette.** Its Ghostty target hardcodes the
bright half as the normal half:

```nix
"9=${base08}" "10=${base0B}" … "14=${base0C}"
```

Slots 0 and 7 are additionally seized for background/foreground. **Eight of the
sixteen values would come out wrong**, and the entire point of this ring — that
each normal/bright pair is held ΔE00 ≥ 10 apart so `\e[31m` and `\e[91m` keep
meaning different things — is destroyed. Its VS Code template also forces
`workbench.colorTheme = "Stylix"`, evicting the editor theme. Cost to adopt:
**+16 `flake.lock` nodes** (62 → 78), including `nix-community/NUR`, against a
lock deliberately held on a `follows` diet.

**[base16.nix](https://github.com/SenchoPens/base16.nix) was the close
runner-up** and lost narrowly: +2 nodes, MIT, no nixpkgs dependency, and it
round-trips the ring byte-identically. It loses on two counts:

1. **It carries no fonts at all**, so `font.face` / `font.sizes` /
   `font.postScriptName` would have to be hand-written anyway — it solves at most
   half the problem.
2. **Its base24 vocabulary fuses roles this palette splits**: `base00` → ANSI 0
   and `base05` → ANSI 7. Here `background` is deliberately distinct from slot 0
   (which is the `\e[40m` *surface*, not the window) and `foreground` from slot 7.
   Two of eighteen values would live in slots whose spec names lie.

Reuse is weighted ~2× in this repo and it still lost. The genuine reuse win was
never a theme framework — it was `programs.ghostty.themes`,
`workbench.colorCustomizations`, and Terminal's Apple Events dictionary, all of
which are upstream surfaces this repo already owned.

**Upgrade path, if the 500-scheme library ever becomes attractive:** swap the
`ansi` list for a `mkSchemeAttrs` call *inside* the provider. Consumers are
untouched — the `config.lib.terminalTheme` contract is deliberately
provider-agnostic.

## Changing a colour

1. Edit `local.terminalTheme` in `modules/shared/terminal-theme.nix`, keeping the
   measured justification beside the value.
2. `git add -A && nix flake check` — the type rejects anything that is not
   uppercase `#RRGGBB`, and the ring must be exactly 16 entries.
3. `activate` from nix-personal. **Never** `darwin-rebuild switch --flake .#macos`
   from this repo.
4. Run `ghostty +validate-config` on the live Mac. `package = null` means
   home-manager's own `onChange` validation is inert (pinned
   `modules/programs/ghostty.nix:160-163`), so nothing checks Ghostty's config at
   build time.

## Gates that proved each step

| Step | Gate |
|---|---|
| Provider lands (#489) | `darwin-system` **drvPath byte-identical** before/after |
| Ghostty (#490) | all 19 colour lines moved **byte-identically** into `themes/fleet`; rest of `ghostty/config` unchanged |
| VS Code (#492) | full `userSettings` diff — **0 keys added/removed**, only the 7 drifted slots + cursor changed; ring **converges 16/16** with Ghostty's |
| Terminal.app (#493) | generated AppleScript **compiles clean** under `osacompile` (validates property names without executing) |
