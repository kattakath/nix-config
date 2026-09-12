# ---- The capsule scaffold (ADR-002 wave 3) ----------------------------------
#
# `modules/parts/` is the ENGINE and may reach in. `modules/features/<name>/` are
# CAPSULES and may not reach out. Deleting seven repo boundaries deletes the only
# mechanical isolation this fleet had, so the boundary is re-created as two
# mechanisms rather than as a sentence in a document (ADR-002 §2):
#
#   FILE layer    ast-grep/rules/capsule-must-not-reach-out.yml — a `files:`-scoped
#                 rule on `kind: path_expression`, severity error, riding the
#                 already-existing `checks.<system>.ast-grep` gate. No new tool,
#                 input or gate.
#   OPTION layer  each capsule's own module checks (e.g. the satellite eval checks
#                 carried over into `modules/features/*/checks/`).
#
# UPSTREAM FIRST → ✅ `flake-parts.flakeModules.modules` exists → using it.
# Pinned flake-parts `extras/modules.nix:32-73` declares
# `flake.modules.<class>.<name>` as `lazyAttrsOf (lazyAttrsOf deferredModule)`,
# with an `apply` (:12-28) that stamps `_class` and a `_file` pointing back at
# the defining flake. That is upstream's own registry for "groups of modules
# published by the flake" — precisely what a capsule exports — so no bespoke
# passthrough is written here. It is NOT a builtin: it must be imported, which is
# what the `imports` line below is for.
{
  config,
  lib,
  inputs,
  ...
}:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];

  # ---- The capsule registry ------------------------------------------------
  # Each capsule's flake-module.nix appends its own directory name. This is NOT
  # under `flake.`, so it is an internal option, never a flake output.
  #
  # A plain `listOf str` rather than an attrset: the ONLY question this answers
  # is "which capsules did import-tree actually load", and list merging across
  # files is the module system's default.
  options.capsules = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Directory names under `modules/features/` whose `flake-module.nix` was
      actually imported. Asserted against the directory listing by
      `checks.<system>.capsule-registry`.
    '';
  };

  # ---- The RAW module seam, and why it is not `flake.modules` -------------
  #
  # MEASURED, wave 4: routing a HOME-MANAGER capsule module through
  # `flake.modules.<class>.<name>` changes what the fleet BUILDS.
  #
  # `flake.modules`' element type is `types.deferredModule`, whose merge ALWAYS
  # wraps every definition — pinned nixpkgs lib/types.nix,
  # `deferredModuleWith`: `merge = loc: defs: { imports = … map … defs; }`.
  # flake-parts then wraps again for any class but `generic`
  # (extras/modules.nix:14-27). So a consumer that writes
  # `imports = [ config.flake.modules.homeManager.x ]` is NOT importing the
  # module — it is importing a module that imports it, one or two levels down.
  #
  # For a NixOS module that is invisible: the config is attribute-keyed, so
  # collection order does not reach the output. For a home-manager module it is
  # NOT: `home.packages` is a LIST, its definitions merge in module-collection
  # order, and that order is `buildEnv`'s `paths` order in `home-manager-path`
  # — which decides who wins a filename collision. Measured on `macos`: routing
  # the keychain-secrets module through `flake.modules` (either class, and
  # `generic` too) moved its four CLIs ahead of postgresql and nix-bedrock-gate
  # in that list and changed `darwin-system…drv`, with byte-identical package
  # derivations. Importing the same path directly restored it exactly.
  #
  # Hence a second seam, `lazyAttrsOf raw`, which passes a definition through
  # UNCHANGED. Same shape as `flake.modules` (class, then name) so a capsule
  # reads the same either way; same file-level contract (flake-module.nix is
  # still the only export point). The two nixos capsules stay on
  # `flake.modules` — they are already baselined that way and gain the `_class`
  # stamp for free; a class whose merge order is load-bearing uses this instead.
  options.capsuleModules = lib.mkOption {
    type = lib.types.lazyAttrsOf (lib.types.lazyAttrsOf lib.types.raw);
    default = { };
    description = ''
      Capsule-exported modules for module classes whose COLLECTION ORDER is
      observable in the built output (home-manager's `home.packages`, say).
      Keyed `<class>.<name>`, mirroring `flake.modules`, but `raw` so the
      definition reaches the consumer unwrapped. Not a flake output.
    '';
  };

  # `config = { … }` is MANDATORY here, not style: this file declares a top-level
  # `options`, and the module system then refuses a bare sibling attribute
  # ("unsupported attribute `perSystem'. This is caused by introducing a
  # top-level `config' or `options' attribute"). Every other modules/parts/*.nix
  # is options-free and so may use the shorthand.
  config.perSystem =
    { pkgs, ... }:
    {
      # ---- The mandatory companion to import-tree's `.match` -----------------
      # ADR-002 §4 finding S3: flake.nix reaches the capsules with an
      # import-tree regex that ends in `/flake-module\.nix`. A capsule whose
      # entry file is MISNAMED is therefore simply never imported — its module
      # never registers, its checks never appear, and `nix flake check` is
      # GREEN, because a check that does not exist cannot fail. That is the
      # worst failure shape available here: a silently absent feature.
      #
      # This closes it from the other side. `readDir` sees the directory
      # regardless of what the file inside is called; `config.capsules` sees only
      # what was imported. A mismatch in either direction is a build failure.
      checks.capsule-registry =
        let
          onDisk = lib.sort lib.lessThan (
            lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ../features))
          );
          registered = lib.sort lib.lessThan config.capsules;
        in
        pkgs.runCommand "capsule-registry" { } ''
          onDisk=${lib.escapeShellArg (lib.concatStringsSep " " onDisk)}
          registered=${lib.escapeShellArg (lib.concatStringsSep " " registered)}
          if [ "$onDisk" != "$registered" ]; then
            echo "capsule-registry: modules/features/ and the imported capsule set disagree." >&2
            echo "  on disk    : $onDisk" >&2
            echo "  registered : $registered" >&2
            echo "" >&2
            echo "A directory present but NOT registered almost always means its entry" >&2
            echo "file is not named flake-module.nix, so flake.nix's import-tree regex" >&2
            echo "never loaded it — a whole capsule silently absent with CI green." >&2
            echo "A name registered but NOT on disk means a stale \`capsules = [ … ]\`." >&2
            exit 1
          fi
          echo "capsules: $registered" > "$out"
        '';
    };
}
