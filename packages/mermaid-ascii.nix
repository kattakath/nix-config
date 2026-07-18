# mermaid-ascii — render Mermaid graphs as ASCII in the terminal
# (AlexanderGrooff/mermaid-ascii). NOT in nixpkgs as of 2026-07, so it is packaged
# here as a buildGoModule straight from upstream, pinned to a release tag.
#
# To bump: change `version`, refresh `src.hash`
#   nix-prefetch-url --unpack https://github.com/AlexanderGrooff/mermaid-ascii/archive/refs/tags/<v>.tar.gz
#   nix hash convert --hash-algo sha256 --to sri <base32>
# and `vendorHash` (set it to lib.fakeHash, build once, copy the reported hash).
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "mermaid-ascii";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "AlexanderGrooff";
    repo = "mermaid-ascii";
    rev = version; # upstream tags are bare "1.4.0" (no leading v)
    hash = "sha256-BAO0WnKbkHTkoZRZFtPuMiJvOcfBndeoShEym1QrFzs=";
  };

  vendorHash = "sha256-aB9sbTtlHbptM2995jizGFtSmEIg3i8zWkXz1zzbIek=";

  meta = {
    description = "Render Mermaid graphs as ASCII in your terminal";
    homepage = "https://github.com/AlexanderGrooff/mermaid-ascii";
    license = lib.licenses.mit;
    mainProgram = "mermaid-ascii";
    platforms = lib.platforms.unix;
  };
}
