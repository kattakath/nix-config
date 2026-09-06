# The fleet's terminal palette + type, held once.
#
# Every terminal-ish surface on this fleet used to carry its OWN copy of the
# Ubuntu ring: Ghostty's `palette` list, VS Code's `terminal.ansi*` keys, and the
# type size Terminal.app is held at. Three copies, no shared source, and they had
# already drifted — VS Code still held pre-lift Tango in seven of sixteen slots,
# i.e. exactly the seven the WCAG work below exists to fix.
#
# This module is that source. It is DATA plus two derivations, deliberately:
#
#   * NO packages, NO activation, NO platform gate. It is pure options, so it
#     evaluates on aarch64-linux as happily as on aarch64-darwin. Each CONSUMER
#     keeps its own gate (Ghostty is `isMacosHost`, VS Code is `isDarwin`).
#   * The derived surface hangs off `config.lib`, which is home-manager's own
#     documented extension point for exactly this — `lib.mkOption` of
#     `attrsOf attrs`, pinned home-manager modules/misc/lib.nix:5. It is the same
#     seam `config.lib.base16` and `config.lib.stylix` use.
#
# WHY NOT STYLIX, the answer everyone reaches for first: its Ghostty target
# hardcodes `"9=${base08}" "10=${base0B}" … "14=${base0C}"`, i.e. every BRIGHT
# slot is emitted as its NORMAL partner, and slots 0 and 7 are seized for
# background/foreground. Eight of the sixteen values below would come out wrong
# and the measured pair separation would be gone — for +16 flake.lock nodes
# against a lock deliberately held at 62. base16.nix was the close runner-up
# (+2 nodes, round-trips the ring exactly) and lost on two counts: it carries no
# fonts at all, and its base24 vocabulary FUSES background with ANSI 0 and
# foreground with ANSI 7, the two roles this palette deliberately splits.
#
# grepped home-manager/modules + nix-darwin/modules for terminal/palette/ansi/
# colorScheme/theme — no fleet-wide palette or typography provider option exists
# → custom, for the reasons above. The per-surface options it feeds (Ghostty's
# `themes`, VS Code's `userSettings`) are all upstream.
{
  config,
  lib,
  ...
}:
let
  cfg = config.local.terminalTheme;

  hexColour = lib.types.strMatching "#[0-9A-F]{6}";

  # The ring is INDEXED, not named, because that is what the ANSI slot numbers
  # are — `byName` below is the convenience view, not the storage.
  ansiRing = lib.types.addCheck (lib.types.listOf hexColour) (l: builtins.length l == 16) // {
    description = "16-element list of uppercase #RRGGBB";
  };

  slotNames = [
    "black"
    "red"
    "green"
    "yellow"
    "blue"
    "magenta"
    "cyan"
    "white"
    "brightBlack"
    "brightRed"
    "brightGreen"
    "brightYellow"
    "brightBlue"
    "brightMagenta"
    "brightCyan"
    "brightWhite"
  ];
in
{
  options.local.terminalTheme = {
    enable = lib.mkEnableOption "the fleet terminal palette + type provider" // {
      default = true;
    };

    background = lib.mkOption {
      type = hexColour;
      default = "#300A24";
      description = ''
        The terminal ground. DISTINCT from ANSI slot 0 on purpose: slot 0 is the
        `\e[40m` surface, this is the window. Conflating them is what the base16
        vocabulary does and why it was rejected.
      '';
    };

    foreground = lib.mkOption {
      type = hexColour;
      default = "#FFFFFF";
      description = ''
        The terminal ink. DISTINCT from ANSI slot 7 on purpose, for the same
        reason `background` is distinct from slot 0. 17.58:1 against the ground.
      '';
    };

    cursor = lib.mkOption {
      type = hexColour;
      default = cfg.foreground;
      defaultText = lib.literalExpression "config.local.terminalTheme.foreground";
      description = "Cursor colour. Follows `foreground` unless a host says otherwise.";
    };

    ansi = lib.mkOption {
      type = ansiRing;
      description = ''
        The 16-slot ANSI ring, list index == slot number. This is the single
        source of truth for every terminal surface in the fleet.

        CANONICAL UBUNTU, verbatim from Ptyxis's own Ubuntu.palette (Ubuntu's
        terminal since 24.10) — not a derivation, and not the macOS
        approximation this repo used to vendor as modules/shared/terminal/
        Ubuntu.terminal (dropped in #319; it used #24081B and a DIFFERENT ANSI
        set entirely, dE00 4.12 away on the ground alone).

        The ring is Tango, which is what Ubuntu has shipped for years. Measured
        against #300A24, SIX of sixteen slots failed WCAG AA. Five are lifted
        here; only slot 0 keeps its authentic value, for a measured reason.

        THE LIFT MOVES LIGHTNESS ONLY. Each colour was converted to OKLab, its L
        raised until it reaches 4.5:1 against #300A24, and converted back with
        hue and chroma untouched — every hue shifted by <= 0.6 deg, so red still
        reads as Tango red.

        PAIRS ARE SOLVED TOGETHER, which is the part that is not obvious.
        Lifting a normal slot alone collapses it onto its bright partner: red
        lifted to AA lands dE00 1.55 from br-red, i.e. the same colour, and
        \e[31m vs \e[91m stops meaning anything. So each bright partner is
        pushed further until the pair is dE00 >= 10 apart:

          red      #CC0000 -> #F03C2E 4.51:1   br #EF2929 -> #FF6B5E   pair 10.02
          blue     #3465A4 -> #5083C4 4.51:1   br #729FCF -> #74A2D2   pair 10.21
          magenta  #75507B -> #9A74A1 4.51:1   br #AD7FA8 -> #BD8FB8   pair 10.04
          br-black #555753 -> #7F827D 4.51:1

        Naively "using the bright variant" does NOT work and was measured first:
        br-red is 4.20:1 and br-black 2.41:1, both still failing, and black has
        no brighter Tango variant at all.

        SLOT 0 IS LEFT AUTHENTIC at 1.39:1, deliberately. It is the `\e[40m`
        SURFACE, not ink: lifting it to pass as ink drops white-on-`\e[40m` from
        12.65:1 to 3.90:1, trading a passing role for a failing one.

        Result: 5 of the 6 AA failures fixed, min pairwise dE00 among slots 0-7
        IMPROVES 23.32 -> 24.14, total drift from authentic dE00 71.8 over 7
        moved slots.
      '';
      default = [
        "#2E3436" # 0  black        — authentic Tango, the \e[40m surface
        "#F03C2E" # 1  red          — lifted from #CC0000
        "#4E9A06" # 2  green
        "#C4A000" # 3  yellow
        "#5083C4" # 4  blue         — lifted from #3465A4
        "#9A74A1" # 5  magenta      — lifted from #75507B
        "#06989A" # 6  cyan
        "#D3D7CF" # 7  white
        "#7F827D" # 8  brightBlack  — lifted from #555753
        "#FF6B5E" # 9  brightRed    — pushed off #F03C2E
        "#8AE234" # 10 brightGreen
        "#FCE94F" # 11 brightYellow
        "#74A2D2" # 12 brightBlue   — pushed off #5083C4
        "#BD8FB8" # 13 brightMagenta— pushed off #9A74A1
        "#34E2E2" # 14 brightCyan
        "#EEEEEC" # 15 brightWhite
      ];
    };

    font = {
      face = lib.mkOption {
        type = lib.types.str;
        default = "UbuntuMono Nerd Font";
        description = "Display family name, as a terminal emulator asks for it.";
      };

      sizes = {
        ghostty = lib.mkOption {
          type = lib.types.ints.positive;
          default = 18;
          description = ''
            NOT a typo against the 16 the other surfaces use. Ghostty rasterizes
            thinner than Terminal.app at the same nominal size, so per-surface
            sizes are modelled rather than flattened to one number.
          '';
        };

        vscodeTerminal = lib.mkOption {
          type = lib.types.ints.positive;
          default = 16;
          description = "VS Code's integrated terminal. See `ghostty` for why these differ.";
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Derived views. Nothing here is a second source of truth — each is a pure
    # function of the options above, in the wire format one consumer wants.
    lib.terminalTheme = {
      inherit (cfg)
        background
        foreground
        cursor
        ansi
        font
        ;

      # Slot number -> role name, for consumers that key by name (VS Code's
      # terminal.ansiBrightBlack, fzf's colour names, …).
      byName = lib.listToAttrs (
        lib.imap0 (i: name: lib.nameValuePair name (builtins.elemAt cfg.ansi i)) slotNames
      );

      # Ghostty's own wire format for a palette entry: "N=#RRGGBB".
      ghosttyPalette = lib.imap0 (i: colour: "${toString i}=${colour}") cfg.ansi;
    };
  };
}
