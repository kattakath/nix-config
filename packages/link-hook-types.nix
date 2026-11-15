# Points `.claude/hooks/node_modules` at the SAME store tree `checks.<system>.hook-types`
# type-checks against, so an editor's TypeScript LSP (Claude Code's
# typescript-language-server plugin) sees the CI view instead of false TS2307/TS2591
# errors. Run by the devShell's shellHook and by `nix run .#link-hook-types`.
#
# Nix's own GC-root out-link, not a hand-rolled `ln -s`: `nix-store --realise --add-root
# <link> --indirect` is what `nix build --out-link` does. Measured 2026-11-07: it
# replaces an existing symlink in place (idempotent, so a pin bump refreshes it), REFUSES
# an existing real directory ("cannot create symlink …; already exists" — an `npm
# install` there is never clobbered), and registers the link as a GC root, so a store GC
# cannot leave it dangling. Rejected: nixpkgs' `importNpmLock.hooks.linkNodeModulesHook`
# — idempotent too, but it roots nothing, needs a node runtime, and reads its tree from
# `importNpmLock.buildNodeModules` (see hook-types-node-modules.nix for why not that).
#
# Uses the `nix-store` already on PATH (the operator's Nix), not a pinned copy.
{
  writeShellApplication,
  git,
  hookTypesNodeModules,
}:
writeShellApplication {
  name = "link-hook-types";
  runtimeInputs = [ git ];
  text = ''
    root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "link-hook-types: not inside a git checkout of nix-config; nothing linked" >&2
      exit 1
    }
    if [ ! -f "$root/.claude/hooks/tsconfig.json" ]; then
      echo "link-hook-types: $root has no .claude/hooks/tsconfig.json; nothing linked" >&2
      exit 1
    fi
    # A checkout this user cannot write (the devcontainer smoke test bind-mounts the
    # runner's tree and runs as another uid) gets a one-line skip, not Nix's own
    # symlink error: this link is an editor nicety, and that error text is exactly
    # what the smoke test treats as a broken shellHook (build-devcontainer-impl.yml).
    if [ ! -w "$root/.claude/hooks" ]; then
      echo "link-hook-types: $root/.claude/hooks is read-only for this user; nothing linked" >&2
      exit 1
    fi
    nix-store --realise ${hookTypesNodeModules} \
      --add-root "$root/.claude/hooks/node_modules" --indirect >/dev/null
  '';
}
