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
# AUTH: a GitHub App (2026-08-23, upgraded from a static PAT — see git history for
# the PAT version). Rather than a long-lived bearer credential sitting in a public
# repo's git history forever, the agenix secret here is the App's RS256 PRIVATE KEY
# (`config.age.secrets."gh-app-${org}-key"`), which every registration attempt uses
# to mint a fresh, ~1-hour-lived installation access token on the spot (JWT →
# `POST /app/installations/{id}/access_tokens`, GitHub's own documented flow) — the
# thing that ever touches the runner's `--pat` is a short-lived derived token, never
# the long-lived key itself. Narrower than a PAT's scope model too: the App is
# granted ONLY "Organization permissions → Self-hosted runners: Read and write",
# not `admin:org`'s much wider bundle (org members, teams, webhooks, ...).
# OUTBOUND-only — the runner polls GitHub, opens no port.
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
  # Upstream nixpkgs' `github-runner` only bundles `externals/node24` — Node 20 was EOL'd
  # and dropped from nixpkgs entirely (pkgs/by-name/gi/github-runner/package.nix: "Node.js
  # 20.x has reached EOL and was removed from Nixpkgs, thus omitted here"), so its
  # `nodeRuntimes` option has no `nodejs_20` left to point at even if overridden. But many
  # GitHub-authored actions (actions/checkout@v4, actions/setup-node@v4, ...) still declare
  # `using: node20` in their action.yml, and the runner execs `externals/node<version>/bin/
  # node` verbatim per-action — so a plain `pkgs.github-runner` fails those steps with
  # "No such file or directory".
  #
  # Fix: `overrideAttrs` with an extra `node20 -> node24` symlink, `doCheck = false` to skip
  # the package's (slow, unrelated) test suite. MUST be overrideAttrs, not a cheaper `lndir`
  # mirror-on-top: Runner.Worker/Runner.PluginHost are compiled .NET binaries whose own
  # `hashFiles()` implementation (used by `actions/cache@v4`'s `key:` expression) resolves
  # its externals path via its OWN physical (symlink-realpath'd) install location, not the
  # path it was invoked through — proven by grepping the compiled binary for its own store
  # hash. An `lndir` shim's binaries are symlinks BACK to the original, un-fixed store path,
  # so that internal lookup still misses; only a true rebuilt derivation (self-referencing
  # its own `$out`, symlink included) satisfies it. `doCheck = false` keeps this fast — the
  # package doesn't recompile the runner from C# source, just repatches prebuilt release
  # binaries, so skipping its dotnet test suite is what makes this a normal-length build.
  runner = pkgs.github-runner.overrideAttrs (old: {
    doCheck = false;
    postInstall = (old.postInstall or "") + ''
      ln -s node24 $out/lib/externals/node20
    '';
  });
  appKeyFile = config.age.secrets."gh-app-${cfg.org}-key".path;

  # Mints a fresh, short-lived (~1hr) installation access token from the App's
  # long-lived private key — GitHub's own documented JWT-then-exchange flow
  # (https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).
  # Shared by every instance's `configure` script (each calls this fresh on every
  # re-registration, not a shared cached token — ephemeral re-registration means
  # this runs often enough that a 1hr token never goes stale mid-use anyway).
  mintInstallationToken = pkgs.writeShellApplication {
    name = "mint-installation-token-${host}-${cfg.org}";
    runtimeInputs = with pkgs; [
      openssl
      curl
      jq
    ];
    text = ''
      now=$(date +%s)
      iat=$((now - 60)) # 60s in the past, tolerates clock skew
      exp=$((now + 600)) # 10 minutes — the max GitHub allows for the JWT itself

      b64enc() { openssl base64 -A | tr -d '=' | tr '/+' '_-'; }

      header=$(printf '{"typ":"JWT","alg":"RS256"}' | b64enc)
      payload=$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$iat" "$exp" ${toString cfg.appId} | b64enc)
      signature=$(
        printf '%s.%s' "$header" "$payload" \
          | openssl dgst -sha256 -sign ${lib.escapeShellArg appKeyFile} \
          | b64enc
      )
      jwt="$header.$payload.$signature"

      curl -sf -X POST \
        -H "Authorization: Bearer $jwt" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/${toString cfg.installationId}/access_tokens" \
        | jq -r .token
    '';
  };

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
        runtimeInputs = [
          runner
          mintInstallationToken
        ];
        text = ''
          export RUNNER_ROOT
          token=$(${lib.getExe mintInstallationToken})
          ${lib.getExe' runner "config.sh"} \
            --unattended \
            --disableupdate \
            --work ${lib.escapeShellArg workDir} \
            --url ${lib.escapeShellArg "https://github.com/${cfg.org}"} \
            --name ${lib.escapeShellArg instanceName} \
            --replace \
            --ephemeral \
            --pat "$token"
        '';
      };
      # ARG0 IS DELIBERATELY /bin/sh HERE — the one sanctioned exception to
      # .claude/rules/launchd-naming.md for a unit this repo authors. Read that
      # rule's "boot-ordering exception" section before changing this back.
      #
      # `/nix` is a SEPARATE `noauto` APFS volume mounted by determinate-nixd.
      # ProgramArguments[0] lives inside it, so at boot launchd tries to exec a
      # path that does not exist yet. Measured 2026-09-06:
      #
      #   12:33:27.417  launchd: "Missing executable detected" x2 -> exit 78 EX_CONFIG
      #   12:33:28.393  determinate_nixd: "Unlocking and mounting /nix"   (976 ms LATE)
      #
      # It then NEVER self-heals: launchd parks the job on an "Executable
      # appearance" retry event which does not fire when the file arrives via a
      # volume mount. Both daemons sat at `runs = 1, state = spawn scheduled`
      # for a 10h52m uptime, and `darwin-rebuild switch` did not recover them
      # either (nix-darwin only re-bootstraps daemons whose plist CHANGED).
      #
      # NO launchd setting recovers a failed exec. Measured with a throwaway
      # agent pointing at a missing executable, then creating it:
      #   StartInterval = 10          -> runs stayed 1 (no retry)
      #   KeepAlive = true            -> runs stayed 1 (no retry)
      #   KeepAlive.PathState         -> rejected: dict keys are OR'd, so it
      #                                  defeats `Crashed = false`, AND it does
      #                                  not fire on volume mounts either.
      # The executable must EXIST when launchd first tries. That means arg0 has
      # to be a path outside /nix, and the only maintained one is a shell doing
      # wait4path — which is exactly what nix-darwin itself emits.
      #
      # upstream option nix-darwin.launchd.daemons.<name>.command exists
      # (modules/launchd/default.nix:90-94 —
      #  ProgramArguments = [ "/bin/sh" "-c" "/bin/wait4path /nix/store && exec ${command}" ])
      # -> using it, rather than hand-rolling a stub outside the store.
      #
      # The rule's LOAD-BEARING half does not apply here anyway: it exists so an
      # adhoc-signed /nix/store arg0 keeps TCC read access to ~/Desktop,
      # ~/Documents and ~/Downloads. This is a system DAEMON running as
      # `_github-runner` that only ever touches /var/lib — it reads none of
      # those. Only BTM legibility is lost, and the exec'd process is still
      # nix-github-runner-<instance>.
      runDaemon = pkgs.writeShellApplication {
        name = "nix-github-runner-${instanceName}";
        runtimeInputs = [
          pkgs.findutils
          runner
        ];
        text = ''
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
      };
    in
    {
      inherit
        instanceName
        stateDir
        workDir
        logDir
        configure
        runDaemon
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
      Determinate Nix). Also requires the `gh-app-<org>-key` agenix secret (the
      GitHub App's private key — see secrets/secrets.nix) and this Mac's SSH host
      key as a recipient.'';

    org = lib.mkOption {
      type = lib.types.str;
      example = "dontsell-ai";
      description = ''
        The GitHub org to register against, at the ORG level (github.com/<org>,
        not <org>/<repo>) — one runner-set then serves every repo in that org.
        Deliberately independent of this flake's own top-level `orgName`
        (kattakath, used for cachix/flakeRef/packages) — a runner built for one
        org's CI has no reason to share an identity with this repo's own.
      '';
    };

    appId = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        The GitHub App's numeric ID (shown on the app's settings page — NOT
        secret, this is public identifying info, not a credential). The app must
        have Organization permission "Self-hosted runners: Read and write" and
        nothing else it doesn't need.
      '';
    };

    installationId = lib.mkOption {
      type = lib.types.ints.positive;
      description = ''
        The numeric installation ID for this App on `org` (shown in the URL when
        viewing the installation in org settings — also not secret on its own;
        it grants nothing without the private key).
      '';
    };

    count = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        How many parallel runner instances to register (each gets its own
        state/work/log dir and launchd daemon, all minting from one App). CI
        workflows that fan out into several jobs per run (typecheck/unit/e2e/...)
        only run them in parallel up to however many instances exist here.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The App's private key (agenix), decrypted at activation with this Mac's SSH
    # host key into a `_github-runner`-owned file every instance mints tokens
    # from. Declared HERE (under the enable guard) rather than in hosts/macos.nix,
    # so a disabled runner leaves no secret owned by a user that no longer exists.
    age.secrets."gh-app-${cfg.org}-key" = {
      file = ../../secrets/gh-app-${cfg.org}-key.age;
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
    #
    # grepped nix-darwin/modules for tmpfiles / createDirectories / a
    # directory-creation option — none exists → custom. nix-darwin models no
    # equivalent of NixOS's systemd.tmpfiles.rules; every mkdir in the pinned
    # tree is likewise ad-hoc inside an activation script or a builder
    # (e.g. modules/nix/linux-builder.nix:182, modules/system/launchd.nix:146).
    # This is the canonical `system.activationScripts` trigger from
    # .claude/rules/upstream-first.md, so the verdict is recorded rather than
    # left implicit.
    system.activationScripts.launchd.text = lib.mkBefore (
      lib.concatMapStringsSep "\n" (i: ''
        ${lib.getExe' pkgs.coreutils "mkdir"} -p ${i.stateDir} ${i.workDir} ${i.logDir}
        ${lib.getExe' pkgs.coreutils "chmod"} 0750 ${i.stateDir} ${i.workDir} ${i.logDir}
        ${lib.getExe' pkgs.coreutils "chown"} ${user}:${user} ${i.stateDir} ${i.workDir} ${i.logDir}
      '') instances
    );

    launchd.daemons = lib.listToAttrs (
      map (
        i:
        lib.nameValuePair i.daemonKey {
          # Minimal PATH for actions/checkout + Nix/Playwright/Prisma-shaped
          # workflows. `pkgs.nix` (a daemon client) replaces `config.nix.package`,
          # which is unset under Determinate. `openssl` added 2026-08-23: the
          # app repo's e2e mock-cert generator (tests/e2e/support/cert.ts)
          # `spawnSync("openssl", ...)` bare-name — resolves via PATH, and its
          # absence here surfaced as `res.status === null` (ENOENT) the moment
          # the runner ran a real e2e job for the first time.
          #
          # `postgresql` added 2026-08-29, same failure shape as openssl. The app repo's CI used to
          # provision a throwaway NEON BRANCH for its integration/e2e tiers; Neon is dead and its
          # replacement (Nile) has no branching, so those jobs now `initdb` their OWN ephemeral
          # cluster per run (`scripts/ci-pg-cluster.mts`) and drop it in a finally. That needs
          # initdb/pg_ctl/psql on PATH — without it the job failed `spawnSync psql ENOENT`. It must
          # carry pgvector: migration `20260821025000_enable_pgvector_extension` does
          # `CREATE EXTENSION vector`, and a plain postgresql cannot satisfy it. The cluster is the
          # JOB's own (private data dir + socket, no TCP), so nothing here is shared with, or able
          # to reach, the operator's `dontsell_dev`/`ragdb` server.
          path = with pkgs; [
            bash
            coreutils
            git
            gnutar
            gzip
            openssl
            (postgresql_16.withPackages (p: [ p.pgvector ]))
            nix
            cachix
          ];
          environment = {
            HOME = i.stateDir;
            RUNNER_ROOT = i.stateDir;
          };
          # nix-darwin wraps this as
          #   /bin/sh -c '/bin/wait4path /nix/store && exec <command>'
          # so the daemon survives a boot that races the /nix volume mount.
          # See the long note at runDaemon for why arg0 must leave the store.
          command = lib.getExe i.runDaemon;
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
            # Re-launch every instance if the App's private key is ever rotated
            # (each instance mints its own token fresh per re-registration, so
            # there's no shared cached-token file to watch instead).
            WatchPaths = [ appKeyFile ];
          };
        }
      ) instances
    );
  };
}
