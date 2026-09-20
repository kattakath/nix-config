# Two checks over a throwaway home-manager config (same argument-passing shape as
# every other capsule's checks — a capsule may not import upward):
#
#   module-evaluates  enabled → awscli + aws-sso-util in home.packages, the example
#                     file exists, and there is NO ~/.aws/config target at all
#                     (the shape-not-content boundary, asserted rather than trusted).
#   inert             the ZERO-INSTALL gate: with the module imported and everything
#                     left disabled, home.packages equals a config that never imported
#                     it, and no `.aws/*` file is declared.
{
  home-manager,
  pkgs,
  module,
}:
let
  homeDir = "/Users/tester";
  mkHm =
    modules:
    (home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        {
          home.username = "tester";
          home.homeDirectory = homeDir;
          home.stateVersion = "24.05";
        }
      ]
      ++ modules;
    }).config;
  on = mkHm [
    module
    { local.cloudCli.aws.enable = true; }
  ];
  off = mkHm [ module ];
  bare = mkHm [ ];
  names = c: pkgs.lib.sort pkgs.lib.lessThan (map pkgs.lib.getName c.home.packages);
  awsTargets = c: builtins.filter (n: pkgs.lib.hasInfix ".aws/" n) (builtins.attrNames c.home.file);
in
{
  module-evaluates = pkgs.runCommand "cloud-cli-eval" { } ''
    fail() { echo "cloud-cli-module: $*" >&2; exit 1; }
    case " ${toString (names on)} " in *" awscli2 "*) ;; *) fail "awscli2 not installed when enabled" ;; esac
    case " ${toString (names on)} " in *" aws-sso-util "*) ;; *) fail "aws-sso-util not installed when enabled" ;; esac
    test "${toString (awsTargets on)}" = ".aws/config.example" \
      || fail "expected exactly .aws/config.example under ~/.aws, got: ${toString (awsTargets on)}"
    grep -q '<<ACCOUNT_ID>>' ${
      on.home.file.".aws/config.example".source
    } || fail "example lost its placeholders"
    echo ok > "$out"
  '';

  inert = pkgs.runCommand "cloud-cli-inert" { } ''
    fail() { echo "cloud-cli-inert: $*" >&2; exit 1; }
    test "${toString (names off)}" = "${toString (names bare)}" \
      || fail "importing cloud-cli disabled changes home.packages: ${toString (names off)} vs ${toString (names bare)}"
    test -z "${toString (awsTargets off)}" || fail "disabled module still declares ${toString (awsTargets off)}"
    echo "zero-install: cloud-cli imported+disabled adds nothing" > "$out"
  '';
}
