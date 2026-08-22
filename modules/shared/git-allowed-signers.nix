# Extra git author emails for SSH signature verify (allowed_signers).
#
# Split from home.nix because a module that declares `options` cannot also
# carry bare config attrs (HM error: "unsupported attribute … caused by
# introducing a top-level options attribute"). Fleet default principal stays
# userEmail in home.nix; private identities append here from nix-personal.
{ lib, ... }:
{
  options.kattakath.git.extraAllowedSignersPrincipals = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional allowed_signers principals (emails) for git SSH signature verify.";
  };
}
