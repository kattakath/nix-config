# The Nix implementations a fleet host can run — the ONE list both platforms'
# `local.nixImplementation` options are typed from (modules/darwin/ and
# modules/nixos/nix-implementation.nix). ADR-017 (why Determinate today) and
# ADR-018 (DECIDED 2026-11-27: migrate to upstream, least live host first).
[
  "determinate"
  "upstream"
]
