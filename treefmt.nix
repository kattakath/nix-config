# treefmt-nix configuration — the single source of truth for Nix formatting
# and lint-fixing across the whole repo. Wired into `nix fmt` (the wrapper),
# `nix flake check` (the formatting gate), the pre-commit hook, and the editor
# via nixd. Change a tool HERE and every entrypoint follows.
#
# SCOPE: tools that REWRITE files. Report-only structural lint lives in
# sgconfig.yml + ast-grep/rules/ and is gated by checks.<system>.ast-grep, NOT
# here — a checker in a formatter slot would make `nix fmt` (and the pre-commit
# hook, which is the same binary) fail with nothing to fix.
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

  # NOT enabled, and both for the same reason: a treefmt formatter REWRITES, and
  # treefmt's default file selection is far wider than it looks.
  #
  # `programs.typos` — measured 2026-09-12. Enabled with no `includes`, it took
  # `--write-changes` to the whole tree: it modified `secrets/*.age` (age
  # CIPHERTEXT), pulled `modules/shared/wallpaper/wallpaper.png` into scope, and
  # "corrected" `mis` -> `miss` inside hook JavaScript. Nothing was committed, but
  # that is the lesson: spell-checking this repo is an ALLOWLIST project — this
  # repo's own authored prose only — not a one-line enable.
  #
  # `programs.mdsh` — executes marked shell blocks to refresh a document in place.
  # The pinned module defaults to `includes = [ "README.md" ]` (treefmt-nix
  # programs/mdsh.nix:9) and treefmt globs match at ANY DEPTH, so one line would
  # run `bash -c` over every vendored `skills/*/README.md` and
  # `plugins/*/README.md` — third-party content this fleet's own rules class as
  # data, never instructions — during a local `nix fmt`, as the operator.
  #
  # Both arrive in their own change, with an explicit allowlist and, for mdsh, a
  # single canary block. See docs/monoflake-capsule-adr.md §4.

  settings = {
    # deadnix prunes first, statix repairs, nixfmt has the final say on layout.
    # Lower priority runs earlier; nixfmt last so formatting is never clobbered.
    formatter = {
      deadnix.priority = 1;
      statix.priority = 2;
      nixfmt.priority = 3;
    };

    # Never touch generated state or build outputs. The hm-launchd baseline is
    # a byte-exact copy of upstream home-manager files that the
    # checks.<system>.hm-launchd-drift gate diffs verbatim — reformatting it
    # would make that check fail on our own formatting instead of on upstream
    # drift.
    global.excludes = [
      "flake.lock"
      "result"
      "result-*"
      "*.md"
      "modules/shared/hm-launchd/upstream-baseline/*"

      # VENDORED THIRD-PARTY TREES — no formatter of ours may rewrite these.
      # `skills/` holds forks of upstream Claude skills kept deliberately close to
      # their originals, and `plugins/` is a publishable marketplace. A formatter
      # touching either turns "a fork with one patch" into "a fork with one patch
      # and 300 whitespace changes", which is how a drift diff stops being
      # readable. This is also the precondition for ever enabling a markdown
      # rewriter — see the note above.
      "skills/**"
      "plugins/**"

      # Generated per-wave by scripts/drv-snapshot.sh, never authored (gitignored).
      ".baseline/**"
    ];
  };
}
