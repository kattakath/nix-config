# Self-hosted GitHub Actions runner for the `macos` host — hand-rolled as a
# launchd daemon.
#
# WHY NOT nix-darwin's `services.github-runners`? That module hard-asserts
# `nix.enable = true` (it pulls the runner's `nix` from `config.nix.package`),
# but this Mac runs **Determinate Nix** (`nix.enable = false`; determinate-nixd
# owns the daemon). The two are mutually exclusive, so we reproduce the module's
# launchd setup here and substitute `pkgs.nix` for `config.nix.package`. Nothing
# else differs — same `_github-runner` user, `RUNNER_ROOT` state dir, ephemeral
# re-registration via launchd `KeepAlive.SuccessfulExit`.
#
# AUTH: the GitHub PAT from agenix (`config.age.secrets."gh-runner-token"`,
# wired in hosts/macos.nix with `owner = "_github-runner"` so the daemon can read
# it). OUTBOUND-only — the runner polls GitHub, opens no port.
#
# SECURITY: `--ephemeral` (one job per registration; launchd restarts + the
# script re-registers). This repo is PUBLIC — only trusted push jobs should
# target `runs-on: [self-hosted, macos]`; never fork-PR workflows.
{
  config,
  pkgs,
  lib,
  handleName,
  ...
}:
let
  name = "macos";
  user = "_github-runner";
  stateDir = "/var/lib/github-runner-${name}";
  workDir = "${stateDir}/_work";
  logDir = "/var/log/github-runner-${name}";
  runner = pkgs.github-runner;
  tokenFile = config.age.secrets."gh-runner-token".path;

  configure = pkgs.writeShellApplication {
    name = "configure-github-runner-${name}";
    runtimeInputs = [ runner ];
    text = ''
      export RUNNER_ROOT
      args=(
        --unattended
        --disableupdate
        --work ${lib.escapeShellArg workDir}
        --url ${lib.escapeShellArg "https://github.com/${handleName}/nix-config"}
        --labels 'nix,${name}'
        --name ${lib.escapeShellArg name}
        --replace
        --ephemeral
      )
      # PAT (ghp_/github_pat_) → --pat (config.sh mints its own registration
      # tokens); anything else is treated as a registration token.
      token=$(<"${tokenFile}")
      if [[ "$token" =~ ^ghp_ ]] || [[ "$token" =~ ^github_pat_ ]]; then
        args+=(--pat "$token")
      else
        args+=(--token "$token")
      fi
      ${lib.getExe' runner "config.sh"} "''${args[@]}"
    '';
  };
in
{
  # Managed service user/group (mirrors nix-darwin's own runner module).
  users.users.${user} = {
    uid = lib.mkDefault 533;
    gid = config.users.groups.${user}.gid;
    description = "GitHub Runner service user";
    home = stateDir;
    createHome = false;
    shell = "/bin/bash";
  };
  users.knownUsers = [ user ];
  users.groups.${user} = {
    gid = lib.mkDefault 533;
    description = "GitHub Runner service user group";
  };
  users.knownGroups = [ user ];

  # Create + own the state/work/log dirs as root, BEFORE launchd loads the daemon
  # (mkBefore on the `launchd` activation script, which runs after user creation).
  system.activationScripts.launchd.text = lib.mkBefore ''
    ${lib.getExe' pkgs.coreutils "mkdir"} -p ${stateDir} ${workDir} ${logDir}
    ${lib.getExe' pkgs.coreutils "chmod"} 0750 ${stateDir} ${workDir} ${logDir}
    ${lib.getExe' pkgs.coreutils "chown"} ${user}:${user} ${stateDir} ${workDir} ${logDir}
  '';

  launchd.daemons."github-runner-${name}" = {
    # Minimal PATH for actions/checkout + Nix workflows. `pkgs.nix` (a daemon
    # client) replaces `config.nix.package`, which is unset under Determinate.
    path = with pkgs; [
      bash
      coreutils
      git
      gnutar
      gzip
      nix
      cachix
    ];
    environment = {
      HOME = stateDir;
      RUNNER_ROOT = stateDir;
    };
    script = ''
      # Always clean the working directory.
      ${lib.getExe pkgs.findutils} ${lib.escapeShellArg workDir} -mindepth 1 -delete || true
      # Ephemeral: wipe RUNNER_ROOT so each start is a fresh registration.
      echo "Cleaning $RUNNER_ROOT"
      ${lib.getExe pkgs.findutils} "$RUNNER_ROOT" -mindepth 1 -delete || true
      if [[ ! -f "$RUNNER_ROOT/.runner" ]]; then
        ${lib.getExe configure}
      fi
      exec ${lib.getExe' runner "Runner.Listener"} run --startuptype service
    '';
    serviceConfig = {
      RunAtLoad = true;
      # Restart after a successful (ephemeral) job to re-register; don't spin on crash.
      KeepAlive = {
        Crashed = false;
        SuccessfulExit = true;
      };
      ProcessType = "Interactive";
      ThrottleInterval = 30;
      UserName = user;
      GroupName = user;
      StandardOutPath = "${logDir}/launchd-stdout.log";
      StandardErrorPath = "${logDir}/launchd-stderr.log";
      WorkingDirectory = stateDir;
      # Re-launch if the token changes.
      WatchPaths = [ tokenFile ];
    };
  };
}
