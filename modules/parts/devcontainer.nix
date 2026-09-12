# ---- The devcontainer image, and the ONE x86_64 escape hatch ----------------
#
# The devcontainer image — and ONLY the image, plus the devShell its terminal
# runs — is multi-arch. `systems` stays at the two fleet arches
# (modules/parts/systems.nix); x86_64-linux is reached with flake-parts'
# `withSystem`, which evaluates `perSystem` for a system WITHOUT enrolling it in
# the transposition (pinned flake-parts modules/withSystem.nix:31-34 ->
# modules/perSystem.nix:150, `otherMemoizedSystems`).
#
# ⚠ THE COLLAPSE THIS PREVENTS. Adding "x86_64-linux" to `systems` would produce
# the same two outputs — and ALSO x86_64 `checks`, an x86_64 `formatter` and
# x86_64 `apps`, silently, because flake-parts transposes every perSystem output
# over `systems` (modules/transposition.nix:100-110). Nothing would fail; the
# flake would just start claiming outputs no runner builds and no host uses.
# That is precisely the risk the pre-flake-parts comment at flake.nix:518-535
# was written against, and it is why the two lists stayed separate here.
{
  config,
  inputs,
  withSystem,
  ...
}:
let
  inherit (inputs) nixpkgs;

  inherit (config.fleet)
    orgName
    cachixUrl
    cachixKey
    devcontainerSystems
    ;
in
{
  perSystem =
    {
      config,
      lib,
      system,
      ...
    }:
    {
      # Devcontainer image is a Linux OCI artifact — gate to the linux triple
      # (aarch64-only in this fleet, plus the x86_64 Codespaces variant lifted
      # out below). Built with unfree pkgs (claude-code) and the SHARED dev
      # toolchain, so `nix develop` inside the container resolves from the baked
      # store.
      packages = lib.optionalAttrs (lib.elem system devcontainerSystems) {
        devcontainerImage =
          # Unfree-permitting nixpkgs, ONLY for the devcontainer image
          # (claude-code is unfree). legacyPackages has unfree disabled, so the
          # image needs its own instance. Deliberately scoped here — no other
          # output imports it.
          (import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          }).callPackage
            ../../packages/devcontainer-image.nix
            {
              inherit (config) devPackages;
              # Identity single-sources (not in pkgs, so callPackage can't autofill):
              # the image's os-release HOME_URL + baked nix.conf Cachix lines reuse
              # these instead of re-hardcoding the handle/cache.
              inherit orgName cachixUrl cachixKey;
            };
      };
    };

  # The x86_64-linux half, lifted straight out of the same `perSystem` rather
  # than duplicated. `flake.packages` / `flake.devShells` are `lazyAttrsOf` of
  # `lazyAttrsOf` (flake-parts lib.nix:230-244, `mkTransposedPerSystemModule`),
  # so these definitions MERGE with the transposed fleet-arch ones instead of
  # colliding — one more place the `unique`-vs-`lazyAttrsOf` distinction is what
  # makes a modular layout legal at all.
  flake = withSystem "x86_64-linux" (
    { config, ... }:
    {
      packages.x86_64-linux = { inherit (config.packages) devcontainerImage; };
      # `devcontainer.json` runs `nix develop .#default` as its terminal, so a
      # Codespaces user on x86_64 needs devShells.x86_64-linux.default to exist —
      # without it the container's shell errors out (and the CI smoke test does
      # too). This is NOT the fleet: no host/check/config is generated for
      # x86_64, only the dev environment.
      devShells.x86_64-linux = { inherit (config.devShells) default; };
    }
  );
}
