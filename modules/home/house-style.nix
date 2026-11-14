{
  lib,
  pkgs,
  loginName,
  fullName,
  domainName,
  ...
}:
# The document house style (Google Docs AND PDF), stated ONCE — and the identity it stamps,
# DERIVED, never retyped.
#
# The `house-style` plugin (github:kattakath/skills) builds a Google Doc or a PDF from Markdown
# with scripts. They are public and carry no person: they read the author, the account that must
# own a Doc, and the style values from `$XDG_CONFIG_HOME/house-style/config.json`. This module is
# that file. `author` is `fullName` and `owner` is the Workspace account, spelled exactly as
# `fleet.googleAccount` is (modules/parts/identity.nix). Every input is an identity ARGUMENT —
# `loginName`, `fullName`, `domainName`, which `mkDarwin`/`mkNixos` thread through
# `extraSpecialArgs` — so a `lib.mkDarwin { identity = …; }` consumer renders their own file.
#
# UPSTREAM FIRST — what was checked, and why it is this small:
#
#   * pinned home-manager `modules/programs/pandoc.nix` (`programs.pandoc`: `enable`, `package`,
#     `defaults`, `templates`, `citationStyles`). It writes a pandoc defaults file and wraps
#     pandoc with `--defaults`, so it CAN carry `metadata.author` and a `reference-doc`. It was
#     not used: a reference doc cannot express the table formatting, the diagram centring or
#     the Title Case the plugin's scripts apply, and enabling it installs a wrapped pandoc
#     beside the plain one already in `home.packages` (default.nix).
#   * typix (github:loqusion/typix), the community flake for Typst. Its `buildTypstProject`
#     builds ONE fixed project inside a flake (docs read 2026-11-14); this needs a command that
#     turns any Markdown file into a PDF at run time, also in a cloud session with no Nix. Not
#     adopted — and it would be a new flake input for a job `pkgs.typst` already does.
#   * nixpkgs `google-fonts` ships Google Sans as the VARIABLE font only (google/fonts
#     `ofl/googlesans`, read 2026-11-14). The PDF theme uses static cuts, including the 17pt
#     optical size, so the plugin vendors its fonts and none is installed from here.
#   * nixpkgs has every engine the scripts run on — `pandoc`, `typst`,
#     `python3Packages.python-docx` — and those ARE used below. No package ships the style.
#
# So the Lego is the plainest one: `pkgs.formats.json` renders an attrset and `xdg.configFile`
# places it — the same pair page-lab.nix and plugin-mcp.nix use.
#
# The interpreter follows beancount.nix: an env named by a session variable, NOT a second
# `python3` on PATH. Darwin-only, like `pandoc` in default.nix — documents are made on the Mac,
# and nixpi's closure must not grow for it.
#
# The script rejects a key it does not know, so a typo here fails loudly at run time.
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
      meta = "444746"; # PDF footer
    };
  };
  python = pkgs.python3.withPackages (ps: [
    ps.python-docx # gdoc.py
    ps.pdfminer-six # font_probe.py
  ]);
in
lib.mkMerge [
  {
    xdg.configFile."house-style/config.json".source =
      (pkgs.formats.json { }).generate "house-style-config.json"
        settings;
  }
  (lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    home.packages = [ pkgs.typst ]; # pdf.py; pandoc is already in default.nix
    home.sessionVariables.HOUSE_STYLE_PYTHON = "${python}/bin/python3";
  })
]
