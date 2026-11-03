# ADR-011 step 7: the hourly `fleet-gauges` push (packages/fleet-gauges.nix) as a Home
# Manager launchd agent. The launcher gives it arg0 `nix-fleet-gauges`
# (modules/home/launchd-launcher.nix). It needs the login Keychain, so it is a USER
# agent, and it runs only while the Mac is awake — the `fleet_gauges_last_run`
# gauge makes a missed hour visible rather than silent.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.fleetGauges;
  pkg = pkgs.callPackage ../../packages/fleet-gauges.nix {
    homeProfileDir = config.home.profileDirectory;
    items = import ../_lib/keychain-items.nix;
    inherit (cfg) cloudflareItems;
  };
in
{
  options.local.fleetGauges = {
    enable = lib.mkEnableOption "the hourly fleet-gauges push to Grafana Cloud (ADR-011 step 7)";
    cloudflareItems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Keychain item NAMES of Cloudflare API tokens whose expiry is reported.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkg ];
    launchd.agents.fleet-gauges = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe pkg) ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/fleet-gauges.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/fleet-gauges.log";
      };
    };
  };
}
