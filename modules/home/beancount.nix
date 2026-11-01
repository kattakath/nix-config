# home-manager module: local.beancount — the Beancount toolchain and Fava, on demand.
#
# UPSTREAM FIRST (checked 2026-11-01): home-manager has no `programs.beancount` and no
# `services.fava`; nix-darwin has neither. nixpkgs ships every piece at the versions the
# `beancount` plugin in kattakath/skills is tested against, measured on this flake's pin:
# beancount 3.2.3, beangulp 0.2.0, beanquery 0.2.0, fava 1.30.16, fava-dashboards 2.0.2,
# beancount-language-server 1.9.2.
#
# ONE interpreter for all four packages. The plugin's launcher runs
# "$BEANCOUNT_PYTHON" -I, so the build code imports beancount from the same environment that
# bean-check and fava run in. Separate top-level packages would give three interpreters, and a
# journal checked by one could be read differently by another.
#
# Only the four CLIs go on PATH, not the env's `python3`: putting a second python3 on PATH would
# shadow whichever one a project expects.
#
# NO launchd agent. Fava runs on demand (`--read-only --host 127.0.0.1`) through the plugin's
# fava skill; nothing needs it between reviews, and an always-on web server over a financial
# journal is exposure with no use.
#
# NO DATA PATH in this public repo. `journal` defaults to a symlink the operator points at the
# data folder; the folder's real location never appears here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.beancount;
  env = pkgs.python3.withPackages (
    ps:
    [
      ps.beancount
      ps.beangulp
      ps.beanquery
      ps.fava
      # Custom Fava dashboards (net worth, debt); config is dashboards.tsx next to the
      # journal. nixpkgs 2.0.2, MIT; compiled in the browser, so no node toolchain here.
      ps.fava-dashboards
    ]
    ++ lib.optional cfg.smartImporter (ps.callPackage ../../packages/smart-importer.nix { })
  );
  clis = pkgs.runCommand "beancount-clis" { } ''
    mkdir -p $out/bin
    for b in bean-check bean-format bean-query fava; do
      ln -s ${env}/bin/$b $out/bin/$b
    done
  '';
in
{
  options.local.beancount = {
    enable = lib.mkEnableOption "the Beancount toolchain, Fava and the Beancount language server";

    journal = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/ledger/main.beancount";
      description = ''
        The journal the plugin builds and Fava shows, exported as BEANCOUNT_JOURNAL. The default
        is a path under a symlink the operator creates to the data folder, so no data path is
        written into this repo.
      '';
    };

    favaPort = lib.mkOption {
      type = lib.types.port;
      default = 5000;
      description = "Loopback port for on-demand Fava, exported as FAVA_PORT. Fava's own default.";
    };

    smartImporter = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add smart_importer (and with it scikit-learn and numpy) to the same interpreter, for the
        beancount plugin's `suggest` command. Off by default: it is the only heavy dependency.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      clis
      pkgs.beancount-language-server
    ];
    home.sessionVariables = {
      BEANCOUNT_PYTHON = "${env}/bin/python3";
      BEANCOUNT_JOURNAL = cfg.journal;
      FAVA_PORT = toString cfg.favaPort;
    };
  };
}
