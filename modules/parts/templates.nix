# ---- Flake template ------------------------------------------------------
# `nix flake init -t github:kattakath/nix-config` — scaffold a consumer
# fleet flake (identity override + host deltas over lib.mkDarwin) instead
# of forking this repo; see README.md § Fork this for your own fleet.
# Top-level templates/ (nix flake templates) is DISTINCT from
# packages/templates/ (raw-served Vast.ai provisioner assets).
#
# `flake.templates` is NOT declared as an option anywhere (flake-parts ships no
# templates module), so it rides the freeform `types.unique` type — correct
# here, because exactly one file may own it.
_: {
  flake.templates.default = {
    path = ../../templates/default;
    description = "Starter fleet flake consuming nix-config's lib.mkDarwin with your own identity and host deltas";
  };
}
