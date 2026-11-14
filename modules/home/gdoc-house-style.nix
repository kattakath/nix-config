{
  pkgs,
  loginName,
  fullName,
  domainName,
  ...
}:
# The Google Docs house style, stated ONCE — and the identity it stamps, DERIVED, never retyped.
#
# The `gdoc-house-style` plugin (github:kattakath/skills) builds a Google Doc from Markdown with
# a script. That script is public and carries no person: it reads the author, the account that
# must own the Doc, and the style values from `$XDG_CONFIG_HOME/gdoc-house-style/config.json`.
# This module is that file. `author` is `fullName` and `owner` is the Workspace account, spelled
# exactly as `fleet.googleAccount` is (modules/parts/identity.nix). Every input is an identity
# ARGUMENT — `loginName`, `fullName`, `domainName`, which `mkDarwin`/`mkNixos` thread through
# `extraSpecialArgs` — so a `lib.mkDarwin { identity = …; }` consumer renders their own file.
#
# UPSTREAM FIRST — what was checked, and why it is this small:
#
#   * pinned home-manager `modules/programs/pandoc.nix` (`programs.pandoc`: `enable`, `package`,
#     `defaults`, `templates`, `citationStyles`). It writes a pandoc defaults file and wraps
#     pandoc with `--defaults`, so it CAN carry `metadata.author` and a `reference-doc`. It was
#     not used: a reference doc cannot express the table formatting, the diagram centring or
#     the Title Case the plugin's script applies afterwards, and enabling it installs a wrapped
#     pandoc beside the plain one already in `home.packages` (default.nix).
#   * nixpkgs has `pandoc` and `python3Packages.python-docx`, the two engines the script runs
#     on. No package ships a Google Docs style; there is nothing to adopt.
#
# So the Lego is the plainest one: `pkgs.formats.json` renders an attrset and `xdg.configFile`
# places it — the same pair page-lab.nix and plugin-mcp.nix use. No option, no package, no
# activation, no platform gate: it is one data file and evaluates on every host.
#
# The values are the ones settled on 2026-11-14 (claude/CLAUDE.md § Google Docs house style);
# the script rejects a key it does not know, so a typo here fails loudly at run time.
let
  names = import ../_lib/derived-names.nix;
  settings = {
    identity = {
      author = fullName;
      owner = names.googleAccount { inherit loginName domainName; };
    };
    style = {
      font = "Google Sans";
      # Not Consolas: Docs' Consolas has no box-drawing or arrow glyphs (measured), so borders drift.
      mono = "JetBrains Mono";
      primary = "0B57D0"; # Material blue, as Google uses it
      tint = "E8F0FE"; # table title row / title column
      border = "C4C7C5"; # neutral outline-variant
      text = "1F1F1F";
    };
  };
in
{
  xdg.configFile."gdoc-house-style/config.json".source =
    (pkgs.formats.json { }).generate "gdoc-house-style-config.json" settings;
}
