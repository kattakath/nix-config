# The ONE otelcol-contrib the fleet runs: the Mac's collector (modules/home/claude-otel.nix)
# and the check that feeds it the li run fixtures (`li-runs-allowlist`, modules/parts/checks.nix)
# both take it from here, so the test keeps exercising the binary that ships.
#
# Why Go 1.26: nixpkgs #570062 ("go, buildGoModule: default to 1.27") broke otelcol-contrib
# 0.155.0. Its pinned github.com/cockroachdb/swiss (b0f6560f979b) builds its runtime hooks only
# under `go1.20 && !go1.27`, so Go 1.27 fails with `undefined: hashFn` / `fastrand64`. swiss
# fixed this upstream in aa852fb3c14e ("Enable go 1.27 support"). nixpkgs carries the same
# pin for scion (#587176), and kubo hit the same error in #502938.
#
# DROP the override once nixpkgs' otelcol-contrib builds on its default Go: that is,
# when opentelemetry-collector-releases moves past 0.155.0 (nixpkgs #581121 proposes 0.164.0)
# with a swiss that has aa852fb3c14e, or when nixpkgs pins Go there itself. Under a lock whose
# default Go is still 1.26 the override is a no-op (same drvPath).
pkgs:
(pkgs.opentelemetry-collector-releases.override {
  buildGoModule = pkgs.buildGo126Module;
}).otelcol-contrib
