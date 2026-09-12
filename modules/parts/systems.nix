# ---- The THREE system folds, and why they are still three -------------------
#
# Moved verbatim from flake.nix's `let` block (ADR-002 wave 2). The comment
# below is the whole point of this file: flake-parts tempts you to collapse all
# three into one `systems = [ … ]`, and that collapse is a REGRESSION.
#
#   systems              (flake-parts' own option) = the FLEET arches. Everything
#                        transposed by flake-parts — packages, apps, checks,
#                        devShells, formatter — is generated for exactly these.
#   devcontainerSystems  fleet linux + x86_64-linux, for the IMAGE only.
#   devToolingSystems    fleet + x86_64-linux, for the devShell + its treefmt eval.
#
# ⚠ DO NOT add "x86_64-linux" to `systems` to serve the last two. flake-parts
# transposes every perSystem output over `systems` (pinned flake-parts
# modules/transposition.nix:100-110), so one extra entry would silently spawn
# x86_64 CHECKS, an x86_64 FORMATTER and x86_64 APPS that this flake permits
# nowhere and that no runner will ever build. The x86_64 outputs that DO exist
# are reached through `withSystem "x86_64-linux"` in modules/parts/devcontainer.nix
# — flake-parts' documented escape hatch for exactly this
# (modules/withSystem.nix:31-34 -> perSystem.nix:150, `otherMemoizedSystems`),
# which evaluates perSystem for a system WITHOUT enrolling it in the transposition.
_:
let
  # A 2-SYSTEM aarch64-only FLEET (aarch64-darwin: macos; aarch64-linux: nixpi +
  # nixvm): no x86_64 HOST anywhere. Every package / devShell / check output is
  # generated for the fleet systems. (The devcontainer IMAGE is the one
  # multi-arch output — it adds x86_64-linux via devcontainerSystems below, for
  # Codespaces; that is a dev tool, not a fleet host, so the invariant holds
  # where it matters.)
  linuxSystems = [
    "aarch64-linux"
  ];
  darwinSystems = [
    "aarch64-darwin"
  ];
  allSystems = linuxSystems ++ darwinSystems;

  # The devcontainer image — and ONLY the image — is multi-arch. The FLEET
  # stays aarch64-only (linuxSystems), but the devcontainer is a dev tool, not
  # a host: GitHub Codespaces is x86_64-only, and an arm64-only image qemu-
  # emulates (which breaks the nix-daemon container), so the image is built for
  # both. Kept OUT of linuxSystems on purpose — adding x86_64 there would spawn
  # x86 devShells/checks/formatter and break the single-arch invariant that the
  # actual hosts rely on.
  devcontainerSystems = linuxSystems ++ [ "x86_64-linux" ];

  # Dev-tooling outputs (devShell + its treefmt eval) must cover every arch a
  # human might DEVELOP on: the fleet arches PLUS the devcontainer's x86_64.
  # `devcontainer.json` runs `nix develop .#default` as its terminal, so a
  # Codespaces user on x86_64 needs devShells.x86_64-linux.default to exist —
  # without it the container's shell errors out (and the CI smoke test does
  # too). This is NOT the fleet: no host/check/config is generated for x86_64,
  # only the dev environment. CI builds .#checks.<system> (aarch64 only), never
  # a full `nix flake check`, so no aarch64 runner tries to build this.
  devToolingSystems = allSystems ++ [ "x86_64-linux" ];
in
{
  # flake-parts' own option. THE FLEET ARCHES ONLY — read the ⚠ above.
  systems = allSystems;

  fleet = {
    inherit
      linuxSystems
      darwinSystems
      allSystems
      devcontainerSystems
      devToolingSystems
      ;
  };
}
