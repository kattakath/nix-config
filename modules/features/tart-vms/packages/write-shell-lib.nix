# A sourceable shell library, shellchecked at build time. Plain `writeText` lints
# nothing, and each consumer's `# shellcheck disable=SC1091` stops ITS shellcheck
# at the `source` line, so without this the libraries ship unlinted.
#
# upstream option nixpkgs writeTextFile's `checkPhase` exists → using it (the
# `checkPhase ? ""` argument in pkgs/build-support/trivial-builders); the linter
# is the same shellcheck-minimal writeShellApplication runs on the consumers.
{ writeTextFile, shellcheck-minimal }:
name: text:
writeTextFile {
  inherit name text;
  checkPhase = ''
    ${shellcheck-minimal}/bin/shellcheck -s bash "$target"
  '';
}
