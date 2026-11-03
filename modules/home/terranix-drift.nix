# ADR-012 § 5 step 1: the daily terranix drift check (packages/terranix-drift.nix) as a
# Home Manager launchd agent. The launcher gives it arg0 `nix-terranix-drift`
# (modules/home/launchd-launcher.nix). It is a USER agent because every stack's state
# passphrase and API keys live in the login Keychain. logging.nix picks the log path up
# from launchd.agents on its own; only counts reach it, full plan output stays 0600
# under $XDG_STATE_HOME/nix-config-terranix-drift/.
#
# The package is BUILT IN THE FLAKE ENGINE (modules/parts/terranix.nix), because only
# the engine sees every `*-plan` wrapper. modules/parts/hosts.nix sets `package` for the
# operator Mac, the same lane `page-lab-pick` takes.
{
  config,
  lib,
  ...
}:
let
  cfg = config.local.terranixDrift;
  pkg = cfg.package.override {
    homeProfileDir = config.home.profileDirectory;
    # The healthchecks.io slug, registered in modules/parts/heartbeats.nix;
    # checks.<system>.heartbeat-workflow-parity reads this literal.
    slug = "nix-config-terranix-drift";
  };
in
{
  options.local.terranixDrift = {
    enable = lib.mkEnableOption "the daily terranix drift check (ADR-012 § 5 step 1)";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "The flake's `terranix-drift` package; set by modules/parts/hosts.nix.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "local.terranixDrift.enable needs local.terranixDrift.package (the flake's terranix-drift).";
      }
    ];
    home.packages = [ pkg ];
    launchd.agents.terranix-drift = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe pkg) ];
        # 06:00 local. A run missed while the Mac sleeps fires on wake (launchd's
        # StartCalendarInterval semantics), which is why the heartbeat is a period.
        StartCalendarInterval = [
          {
            Hour = 6;
            Minute = 0;
          }
        ];
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/terranix-drift.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/terranix-drift.log";
      };
    };
  };
}
