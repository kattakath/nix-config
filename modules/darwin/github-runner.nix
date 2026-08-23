# Self-hosted GitHub Actions runner(s) for the `macos` host — hand-rolled as launchd
# daemons. Originally built + retired 2026-07-16 (commit 309751c) when nix-config's
# OWN CI stopped needing it (GitHub-hosted covers this repo; local aarch64-linux
# builds use Determinate's native Linux builder). Revived 2026-08-23 for a DIFFERENT
# consumer: `dontsell-ai`'s repos, whose CI/deploy workflows need real macOS +
# Playwright + Prisma jobs that neither GitHub-hosted (org has no hosted-minutes
# budget configured) nor the native builder (build-only, ephemeral, 1-CPU/8GB — not
# a persistent-daemon host) can serve. Generalized from a single hardcoded instance
# to N parallel ones — `nixvm`'s own runner history already proved 2 in parallel
# before that fleet was retired too.
#
# WHY NOT nix-darwin's `services.github-runners`? That module hard-asserts
# `nix.enable = true` (it pulls the runner's `nix` from `config.nix.package`),
# but this Mac runs **Determinate Nix** (`nix.enable = false`; determinate-nixd
# owns the daemon). The two are mutually exclusive, so we reproduce the module's
# launchd setup here and substitute `pkgs.nix` for `config.nix.package`. Nothing
# else differs — same `_github-runner` user, `RUNNER_ROOT` state dir per instance,
# ephemeral re-registration via launchd `KeepAlive.SuccessfulExit`.
#
# AUTH: a GitHub PAT from agenix (`config.age.secrets."gh-runner-token-${org}"`,
# declared HERE under the enable guard, decrypted with this Mac's SSH host key).
# OUTBOUND-only — the runner polls GitHub, opens no port. Needs `admin:org` scope
# for org-level registration (one runner-set serves EVERY repo in that org, not
# just the one that happened to need it first).
#
# SECURITY: `--ephemeral` (one job per registration; launchd restarts + the script
# re-registers — this is also what makes it self-healing: a crashed or completed
# run just comes back on its own, no manual `svc.sh start`). Only trusted push
# jobs should target `runs-on: [self-hosted, ...]` — never fork-PR workflows,
# since the daemon inherits the operator's login environment.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.macosGithubRunner;
  host = "macos";
  user = "_github-runner";
  runner = pkgs.github-runner;
  tokenFile = config.age.secrets."gh-runner-token-${cfg.org}".path;

  # One instance's derived paths/names, from its 1-based index.
  mkInstance =
    idx:
    let
      suffix = lib.fixedWidthNumber 2 idx;
      instanceName = "${host}-${cfg.org}-${suffix}";
      stateDir = "/var/lib/github-runner-${host}-${cfg.org}-${suffix}";
      workDir = "${stateDir}/_work";
      logDir = "/var/log/github-runner-${host}-${cfg.org}-${suffix}";
      configure = pkgs.writeShellApplication {
        name = "configure-github-runner-${host}-${cfg.org}-${suffix}";
        runtimeInputs = [ runner ];
        text = ''
          export RUNNER_ROOT
          args=(
            --unattended
            --disableupdate
            --work ${lib.escapeShellArg workDir}
            --url ${lib.escapeShellArg "https://github.com/${cfg.org}"}
            --name ${lib.escapeShellArg instanceName}
            --replace
            --ephemeral
          )
          # PAT (ghp_/github_pat_) → --pat (config.sh mints its own registration
          # tokens on every re-register); anything else is treated as a one-shot
          # registration token (won't survive ephemeral re-registration — use a PAT).
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
      inherit
        instanceName
        stateDir
        workDir
        logDir
        configure
        ;
      daemonKey = "github-runner-${host}-${cfg.org}-${suffix}";
    };

  instances = map mkInstance (lib.range 1 cfg.count);
in
{
  options.services.macosGithubRunner = {
    enable = lib.mkEnableOption ''
      self-hosted GitHub Actions runner(s) on the `macos` host (hand-rolled launchd
      daemons — nix-darwin's own `services.github-runners` is incompatible with
      Determinate Nix). Also requires the `gh-runner-token-<org>` agenix secret
      (see secrets/secrets.nix) and this Mac's SSH host key as a recipient.'';

    org = lib.mkOption {
      type = lib.types.str;
      example = "dontsell-ai";
      description = ''
        The GitHub org to register against, at the ORG level (github.com/<org>,
        not <org>/<repo>) — one runner-set then serves every repo in that org.
        Deliberately independent of this flake's own top-level `orgName`
        (kattakath, used for cachix/flakeRef/packages) — a runner built for one
        org's CI has no reason to share an identity with this repo's own.
        Requires a PAT with `admin:org` scope for THIS org.
      '';
    };

    count = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        How many parallel runner instances to register (each gets its own
        state/work/log dir and launchd daemon, all sharing one PAT). CI workflows
        that fan out into several jobs per run (typecheck/unit/e2e/...) only run
        them in parallel up to however many instances exist here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The runner PAT (agenix), decrypted at activation with this Mac's SSH host key
    # into a `_github-runner`-owned file every instance's daemon reads. Declared
    # HERE (under the enable guard) rather than in hosts/macos.nix, so a disabled
    # runner leaves no secret owned by a user that no longer exists.
    age.secrets."gh-runner-token-${cfg.org}" = {
      file = ../../secrets/gh-runner-token-${cfg.org}.age;
      owner = user;
      mode = "0400";
    };

    # Managed service user/group (mirrors nix-darwin's own runner module) — one
    # user shared by every instance; this is a single-operator machine, not a
    # multi-tenant fleet, so per-instance OS-user isolation buys nothing here.
    users.users.${user} = {
      uid = lib.mkDefault 533;
      gid = config.users.groups.${user}.gid;
      description = "GitHub Runner service user";
      home = "/var/lib/github-runner-${host}";
      createHome = false;
      shell = "/bin/bash";
    };
    users.knownUsers = [ user ];
    users.groups.${user} = {
      gid = lib.mkDefault 533;
      description = "GitHub Runner service user group";
    };
    users.knownGroups = [ user ];

    # Create + own every instance's state/work/log dirs as root, BEFORE launchd
    # loads the daemons (mkBefore on the `launchd` activation script, which runs
    # after user creation).
    system.activationScripts.launchd.text = lib.mkBefore (
      lib.concatMapStringsSep "\n" (
        i:
        ''
          ${lib.getExe' pkgs.coreutils "mkdir"} -p ${i.stateDir} ${i.workDir} ${i.logDir}
          ${lib.getExe' pkgs.coreutils "chmod"} 0750 ${i.stateDir} ${i.workDir} ${i.logDir}
          ${lib.getExe' pkgs.coreutils "chown"} ${user}:${user} ${i.stateDir} ${i.workDir} ${i.logDir}
        ''
      ) instances
    );

    launchd.daemons = lib.listToAttrs (
      map (
        i:
        lib.nameValuePair i.daemonKey {
          # Minimal PATH for actions/checkout + Nix/Playwright/Prisma-shaped
          # workflows. `pkgs.nix` (a daemon client) replaces `config.nix.package`,
          # which is unset under Determinate.
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
            HOME = i.stateDir;
            RUNNER_ROOT = i.stateDir;
          };
          script = ''
            # Always clean the working directory.
            ${lib.getExe pkgs.findutils} ${lib.escapeShellArg i.workDir} -mindepth 1 -delete || true
            # Ephemeral: wipe RUNNER_ROOT so each start is a fresh registration.
            echo "Cleaning $RUNNER_ROOT"
            ${lib.getExe pkgs.findutils} "$RUNNER_ROOT" -mindepth 1 -delete || true
            if [[ ! -f "$RUNNER_ROOT/.runner" ]]; then
              ${lib.getExe i.configure}
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
            StandardOutPath = "${i.logDir}/launchd-stdout.log";
            StandardErrorPath = "${i.logDir}/launchd-stderr.log";
            WorkingDirectory = i.stateDir;
            # Re-launch every instance if the shared token changes.
            WatchPaths = [ tokenFile ];
          };
        }
      ) instances
    );
  };
}
