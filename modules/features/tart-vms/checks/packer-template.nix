# The vendored Packer template, validated OFFLINE against the pinned plugin.
#
# Carried over verbatim from github:kattakath/nix-tart-vms's own flake.nix
# `checks.packer-template` (ADR-002 wave 5); only the two `${./…}` literals
# became arguments, because a capsule leaf may not reach up with `..`
# (ast-grep/rules/capsule-must-not-reach-out.yml). ../flake-module.nix passes
# both down.
#
# `packer validate` with PACKER_PLUGIN_PATH pointed at the store is the only
# thing standing between a typo'd HCL block and a `tart-vm bake` that fails
# after downloading an IPSW.
{
  runCommand,
  packer,
  # `packages/packer-plugin-tart.nix`'s output, and the template it validates.
  packerPluginTart,
  template,
}:
runCommand "packer-template-validate"
  {
    nativeBuildInputs = [ packer ];
  }
  ''
    export HOME="$TMPDIR"
    export PACKER_NO_COLOR=1 CHECKPOINT_DISABLE=1
    export PACKER_PLUGIN_PATH=${packerPluginTart}/libexec/packer/plugins
    packer validate ${template}
    touch "$out"
  ''
