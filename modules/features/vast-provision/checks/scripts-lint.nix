# The satellite's `scripts-lint`, KEPT and extended — the only check this
# capsule carries over.
#
# WHAT IT GUARDS. Three shell scripts in this repo can never be
# `writeShellApplication`s, because a live Vast.ai instance fetches them over
# RAW HTTP at boot and runs them on a machine that has no Nix:
#
#   packages/vast-bootstrap.sh                        PROVISIONING_SCRIPT
#   packages/templates/provisioner/provision-lib.sh   PROVISION_LIB_URL
#   packages/templates/provisioner/provision.sh       baked into a scaffolded repo
#
# So they get no shellcheck from being built. A syntax error in any of them is
# invisible to `nix flake check` and surfaces only on a RENTED, BILLED instance,
# as a boot that provisions nothing.
#
# EXTENDED, not merely carried: the satellite lint covered its OWN copies, and
# nix-config's copies — the ones actually served — were never linted at all,
# only diffed against the satellite's by `checks.vast-lib-drift`. With the two
# trees collapsed into one there is nothing left to diff (that check is gone),
# and this lint now runs over the single surviving copy of each file. The
# fourth scaffold asset, `.provisioner-template.json`, is the marker
# `vast-repo-check` fetches to decide whether a repo is a legitimate
# provisioner repo — malformed JSON there fails the same way, on the instance,
# so it is parsed here too rather than left as the one unchecked file in the
# set. (`README.md` is the fifth and is prose; nothing parses it.)
#
# CAPSULE INVARIANT: every path arrives as an ARGUMENT. This file may not reach
# `../../../packages/…` — see ast-grep/rules/capsule-must-not-reach-out.yml —
# and the files it lints are engine-owned precisely because their repo paths
# are a contract with already-stored Vast templates (ADR-002 §4, finding S2).
{
  runCommand,
  shellcheck,
  jq,
  bootstrap,
  provision,
  provisionLib,
  marker,
}:
runCommand "vast-scripts-lint"
  {
    nativeBuildInputs = [
      shellcheck
      jq
    ];
  }
  ''
    shellcheck \
      ${bootstrap} \
      ${provisionLib} \
      ${provision}
    jq -e . ${marker} > /dev/null
    touch "$out"
  ''
