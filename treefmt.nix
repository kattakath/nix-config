# treefmt-nix configuration — the single source of truth for Nix formatting
# and lint-fixing across the whole repo. Wired into `nix fmt` (the wrapper),
# `nix flake check` (the formatting gate), the pre-commit hook, and the editor
# via nixd. Change a tool HERE and every entrypoint follows.
_:

{
  # Anchors the project root for treefmt's file walk.
  projectRootFile = "flake.nix";

  programs = {
    # RFC 166 official style — the de-facto Nix formatter (nixpkgs-fmt is archived).
    nixfmt.enable = true;

    # Anti-pattern linter; in treefmt it runs `statix fix` to auto-repair.
    statix.enable = true;

    # Removes unused bindings / dead let-expressions (`deadnix --edit`).
    deadnix.enable = true;
  };

  settings = {
    # deadnix prunes first, statix repairs, nixfmt has the final say on layout.
    # Lower priority runs earlier; nixfmt last so formatting is never clobbered.
    formatter = {
      deadnix.priority = 1;
      statix.priority = 2;
      nixfmt.priority = 3;
    };

    # Never touch generated state or build outputs.
    global.excludes = [
      "flake.lock"
      "result"
      "result-*"
      "*.md"
    ];
  };
}
