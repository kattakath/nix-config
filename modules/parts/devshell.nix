# ---- Dev toolchain: treefmt-nix + git-hooks.nix + the devShell --------------
#
# UPSTREAM FIRST, and it paid twice here (.claude/rules/upstream-first.md):
#
#   ✅ upstream module `treefmt-nix.flakeModule` exists → using it. Read at
#      pinned treefmt-nix flake-module.nix:72-77: it sets `checks.treefmt` and
#      `formatter` from one `perSystem.treefmt` submodule. That DELETES the
#      hand-rolled `treefmtEval = genAttrs devToolingSystems …` fold and the
#      `formatter = forAllSystems …` line this file replaces.
#      One deliberate deviation: `flakeCheck = false`, because upstream names
#      the check `treefmt` and this repo's gate, its CI job and its docs all say
#      `formatting`. Renaming a public check to match a framework's default is a
#      breaking change disguised as a cleanup, so the check is re-declared under
#      its own name from the very same `build.check`.
#
#   ✅ upstream module `git-hooks.flakeModule` exists → using it. Read at pinned
#      git-hooks.nix flake-module.nix:74 (`checks.pre-commit = cfg.settings.run`)
#      and :79 (`hooks.treefmt.package = mkIf (options?treefmt) (mkOverride 900
#      config.treefmt.build.wrapper)`). That last line is the whole hand-wire the
#      old flake.nix carried — upstream already binds the hook to treefmt's OWN
#      wrapper, so "the commit hook and CI run literally the same binary" is now
#      an upstream guarantee instead of a local convention.
{ config, inputs, ... }:
let
  inherit (inputs)
    nixpkgs
    home-manager
    agenix
    deploy-rs
    treefmt-nix
    git-hooks
    ;
  inherit (config.fleet) darwinSystems;
in
{
  imports = [
    treefmt-nix.flakeModule
    git-hooks.flakeModule
  ];

  perSystem =
    {
      config,
      lib,
      pkgs,
      system,
      ...
    }:
    {
      # ---- Shared dev toolchain -----------------------------------------------
      # Pinned dev tools consumed by BOTH the `nix develop` devShell AND the
      # prebuilt devcontainer image, so the two can never drift.
      # (pre-commit's enabledPackages are added on the devShell side only; the
      # image bakes the treefmt wrapper directly.)
      #
      # A perSystem OPTION rather than a `let` function, so
      # modules/parts/devcontainer.nix can read it for the system it is baking —
      # including the x86_64-linux one it reaches through `withSystem`.
      options.devPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        description = "Dev tools shared by the devShell and the devcontainer image.";
      };

      config = {
        # ---- Formatting / lint (treefmt-nix) ----------------------------------
        # The wrapper backs `nix fmt`; the `.config.build.check` derivation backs
        # the CI formatting gate. `projectRoot` defaults to `self`
        # (flake-module.nix:57-64), which is what the old `…build.check self`
        # passed by hand.
        treefmt = {
          imports = [ ../../treefmt.nix ];
          # See the header: upstream would name this `checks.treefmt`; this repo's
          # gate is `checks.<system>.formatting` and stays that.
          flakeCheck = false;
        };

        checks.formatting = config.treefmt.build.check config.treefmt.projectRoot;

        # ---- Pre-commit hooks (git-hooks.nix) ---------------------------------
        # A single hook runs the treefmt wrapper, so the commit-time tool list can
        # never drift from `nix fmt` / CI — they are literally the same binary
        # (upstream wires the package itself; see the header).
        pre-commit.settings.hooks.treefmt.enable = true;

        devPackages = [
          pkgs.git
          pkgs.nixd # eval-aware Nix LSP
          home-manager.packages.${system}.default
          config.treefmt.build.wrapper # `treefmt` / `nix fmt`
          # nixfmt as a standalone bin so bare `nixfmt` resolves on PATH for the
          # editor (devcontainer.json's nix.formatterPath + nixd formatting.command
          # both invoke it directly). Sourced from treefmt's own resolved package so
          # it can NEVER drift from the binary the wrapper/CI/pre-commit run.
          config.treefmt.programs.nixfmt.package
          pkgs.statix # anti-pattern linter — .vscode "nix: statix" task
          pkgs.deadnix # dead-code linter — .vscode "nix: deadnix" task
          # Structural linter for the checks.<system>.ast-grep gate. Here (and
          # not in treefmt) so rules under ast-grep/rules/ can be iterated with
          # `ast-grep scan` / `ast-grep test` without a full flake check. Binary
          # is `ast-grep` — there is no `sg` alias in the nixpkgs output.
          pkgs.ast-grep
          pkgs.jq # flattens deadnix JSON for the problem matcher
          # agenix secret editing: `agenix -e secrets/<name>.age` (recipients in
          # secrets/secrets.nix). Pure age/SSH — no ssh-to-age needed.
          agenix.packages.${system}.default
        ];

        # ---- Multi-architecture dev shell --------------------------------------
        # `nix develop` on any target. Used as the default Devcontainer profile.
        # statix/deadnix/jq are exposed as standalone binaries (NOT via
        # pre-commit's enabledPackages, which only yields the treefmt wrapper) so
        # the .vscode lint tasks can call them directly.
        #
        # This is generated for the two FLEET arches here; the x86_64-linux
        # devShell the Codespaces terminal needs is lifted out of this same
        # perSystem by modules/parts/devcontainer.nix via `withSystem`, WITHOUT
        # enrolling x86_64 in `systems` (which would also spawn x86 checks, apps
        # and a formatter). See modules/parts/systems.nix.
        devShells.default = pkgs.mkShell {
          # Shared with the devcontainer image (devPackages) so the pinned
          # nixd/treefmt/statix/deadnix/jq/home-manager set never drifts.
          packages =
            config.devPackages
            ++ config.pre-commit.settings.enabledPackages
            # The `deploy` CLI (deploy-rs) — DARWIN ONLY, on purpose. `macos` is
            # the fleet's sole SSH client and the only host holding the operator
            # key + the cloudflared Access path, so a deploy can originate
            # nowhere else. Kept OUT of devPackages because that list is BAKED
            # INTO the devcontainer image (incl. the x86_64 Codespaces variant),
            # which can neither reach the Pi nor justify a from-source Rust build
            # of a tool it cannot use.
            # Sourced from the deploy-rs INPUT rather than `pkgs.deploy-rs`:
            # `activate.nixos` embeds the overlay-built `activate` binary into
            # nixpi's closure, and magic rollback is a handshake between THAT
            # binary and this CLI. nixpkgs carries its own independently-revved
            # copy; taking both from one lock entry keeps them in lockstep.
            #
            # THE PRICE OF THAT LOCKSTEP, stated plainly because it is invisible
            # otherwise: the input's overlay build (`deploy-rs-0.1.0`) is CACHED
            # NOWHERE — verified absent from BOTH cache.nixos.org and
            # kattakath.cachix.org on both arches — whereas `pkgs.deploy-rs`
            # (`0-unstable-*`) substitutes fine. So on a machine that has not
            # built it yet, `nix develop` pays a from-source Rust build, and the
            # first real deploy pays a SECOND one for the aarch64-linux `activate`
            # baked into nixpi's closure (on Determinate's ~1-CPU Linux builder).
            # Deliberately NOT mitigated by adding it to `checks` to warm Cachix:
            # `checks` is what `nix flake check` / `/eval` / nix-ci.yml build and
            # is kept strictly lint-only (see modules/parts/checks.nix) — paying
            # a Rust build on every local `/eval` to save it on the rare fresh-Mac
            # `nix develop` is the worse trade. Budget for it once per machine.
            ++ nixpkgs.lib.optionals (nixpkgs.lib.elem system darwinSystems) [
              deploy-rs.packages.${system}.default
            ];

          # We deliberately DO NOT run git-hooks.nix's installer — which is why
          # `config.pre-commit.shellHook` is referenced NOWHERE in this repo, and
          # why that absence is load-bearing rather than an oversight. That
          # installer would symlink .pre-commit-config.yaml, run
          # `git config core.hooksPath`, and write .git/hooks/pre-commit with a
          # /nix/store bash shebang. But `.git/` is bind-mounted and shared
          # between this Nix devcontainer and the Nix-less macOS host (see
          # .devcontainer/devcontainer.json workspaceMount): a store-path hook
          # installed here makes host-side `git commit` fail with
          # `fatal: cannot exec` — the kernel cannot resolve the /nix/store
          # interpreter off-Nix. A single hook file cannot be correct in both a Nix
          # and a non-Nix environment, so we skip local install entirely. The
          # `checks.pre-commit` CI gate + `nix fmt` run the same treefmt pass, so no
          # coverage is lost; run `nix fmt` before committing.
          shellHook = ''
            echo "nix-config devShell ready on ${system} — run 'nix fmt' before committing (pre-commit auto-install disabled: .git is shared with a Nix-less host; CI enforces the gate)"
          '';
        };
      };
    };
}
