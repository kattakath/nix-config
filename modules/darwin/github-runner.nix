# Self-hosted GitHub Actions runner(s) for the `macos` host — hand-rolled as launchd
# daemons. Originally built + retired 2026-07-16 (commit 309751c) when nix-config's
# OWN CI stopped needing it (GitHub-hosted covers this repo; local aarch64-linux
# builds use Determinate's native Linux builder). Revived 2026-08-23 for a DIFFERENT
# consumer: `dontsell-ai`'s repos, whose CI/deploy workflows need real macOS +
# Playwright + Prisma jobs that neither GitHub-hosted (org has no hosted-minutes
# budget configured) nor the native builder (build-only, ephemeral, 1-CPU/8GB by default — not
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
# because a fork-PR job still runs with real credentials: the daemon has no
# login environment to inherit (it runs as uid 533 `_github-runner` from
# /Library/LaunchDaemons with a bare PATH this module sets itself), but it
# DOES still hold the org token and repo access for its job's duration.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.local.macosGithubRunner;
  host = "macos";
  user = "_github-runner";
  # Upstream nixpkgs' `github-runner` bundles only `externals/node24` BY DEFAULT — Node 20
  # is EOL and omitted from the default `nodeRuntimes` (pinned pkgs/by-name/gi/github-runner/
  # package.nix:19-34), but `override { nodeRuntimes = [ "node24" "node20" ]; }` is still
  # accepted (:27-34, :253-254) and links the real, insecure-flagged nodejs_20, which would
  # need `permittedInsecurePackages`. This module keeps the alias instead: no insecure
  # allowlist, `using: node20` actions run on Node 24 (a deliberate choice, not a nixpkgs
  # limitation — re-decide if an action ever breaks on 24). But many
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

  # ---- IDLE SLEEP KILLS A RUNNING JOB, AND THIS MAC SLEEPS AFTER 1 MINUTE -----
  #
  # `pmset -g custom` reports `sleep 1` on AC **and** battery (measured
  # 2026-10-02). Nothing in this fleet held a power assertion while a CI job ran,
  # so a long job could be cut off mid-flight: red check, truncated log, no
  # legible cause. A busy CPU does not help — macOS' idle-sleep timer counts
  # USER inactivity, not load, so a flat-out 40-minute build is exactly as idle
  # as an empty desktop.
  #
  # upstream option: grepped the PINNED nix-darwin/modules AND
  # home-manager/modules for pmset|caffeinate|IOPMAssertion|idleSleep|
  # powerManagement — ZERO hits in either (home-manager's two `powermanagement`
  # hits are KDE's `powermanagementprofilesrc`, a Linux desktop file) → custom,
  # because neither input models macOS power assertions at all. The nearest
  # upstream surface is `power.sleep.*`, which exists only in nix-darwin's NixOS
  # sibling and would set the pmset DEFAULTS — the wrong instrument: lowering
  # this Mac's idle timer fleet-wide to cover CI would stop an idle laptop
  # sleeping for the other 23 hours of the day.
  #
  # TOOL axis: `/usr/bin/caffeinate` (Apple's own, caffeinate(8), present since
  # 10.8) owns this → using it, un-wrapped. Nothing is added to `runtimeInputs`:
  # caffeinate is a system binary with no nixpkgs package, which is also why the
  # OTHER lane (the `tart-vms` capsule) can hold the same kind of assertion
  # without importing anything from here — the shared thing is a 20-byte absolute
  # path, not a helper that would have to cross the capsule boundary.
  #
  # WHY A JOB HOOK, AND WHY NOT THE UTILITY FORM ON `runDaemon`.
  #
  # `caffeinate -i <utility>` is the shape to reach for in general — its
  # assertion is bound to a PROCESS LIFETIME rather than to an event, and its
  # process topology is the opposite of what caffeinate(8) implies. Measured
  # 2026-10-02:
  #
  #   /usr/bin/caffeinate -i /bin/sleep 60 &
  #   23054 23048 /bin/sleep 60                         <- $! EXEC'd the utility
  #   23056 23054 /usr/bin/caffeinate -i /bin/sleep 60  <- forked watcher asserts
  #
  # So `exec /usr/bin/caffeinate -i … Runner.Listener run` below would have been
  # launchd-safe: launchd would still be tracking Runner.Listener itself, and
  # `KeepAlive.SuccessfulExit` would be untouched.
  #
  # IT IS STILL WRONG HERE, on a second measurement. `--ephemeral` +
  # `KeepAlive.SuccessfulExit` does NOT mean a process per job: between jobs the
  # listener sits in "Listening for Jobs". With NO job running:
  #
  #   65976  etime 57:24  _github-runner  (Runner.Listener)   …-dontsell-ai-01
  #   76673  etime 48:43  _github-runner  (Runner.Listener)   …-dontsell-ai-02
  #
  # Wrapping that holds PreventUserIdleSystemSleep for the whole life of an IDLE
  # runner — permanently, on a host that runs two of them. That is the same harm
  # as a leaked assertion (this Mac never idle-sleeps again) except unconditional
  # rather than crash-only, which makes it strictly worse than the leak it would
  # be preventing. The assertion has to be scoped to the JOB.
  #
  # `ACTIONS_RUNNER_HOOK_JOB_STARTED` is GitHub's documented seam for job scope,
  # and it is the right seam for THIS lane specifically because the runner runs
  # ON THE HOST here, so a hook's assertion is a HOST assertion. The Tart lane
  # cannot use a hook at all — its Runner.Listener runs inside a macOS GUEST
  # (modules/features/tart-vms/packages/tart-runner.nix:705, `exec
  # ./bin/Runner.Listener run` inside a heredoc piped to `guest_ssh` at :707) —
  # so a hook there would caffeinate a disposable VM and leave the host free to
  # sleep. That lane is NOT fixed here: whether Virtualization.framework takes
  # its own assertion while a guest runs is unmeasured, and a fix built on a
  # guess would be surface for nothing. See the PR for the one command that
  # settles it.
  #
  # The hook's cost is that it cannot use the utility form: it must RETURN before
  # the job starts (`exec caffeinate -i …` there would block the job forever), so
  # what it leaves behind is necessarily detached. `-w` is what makes that safe —
  # a bare backgrounded `caffeinate -i &` reparents to pid 1 and asserts
  # unbounded and unattributed, which is a real leak and is NOT what this does.
  #
  # WHY IT CANNOT LEAK: `caffeinate -w <pid>` releases when the watched process
  # exits, with no second step to forget — no job-completed hook (it does not
  # fire on cancel, crash, or ephemeral exit), no pidfile, no kill. The watched
  # pid is an ANCESTOR read from live `ps` while it blocks on this very hook, so
  # it cannot be the already-dead pid that would make `-w` return instantly. The
  # script verifies the assertion landed anyway, because that failure mode is
  # otherwise silent. Measured 2026-10-02: `kill -9` on the watched pid made
  # caffeinate exit on its own, leaving zero assertion rows.
  wakeAssertionHook = pkgs.writeShellApplication {
    # `.sh` IS LOAD-BEARING, not decoration. GitHub resolves the hook's
    # interpreter from the file EXTENSION and a file without `.sh`/`.ps1` does
    # not run — so the usual extensionless `$out/bin/<name>` would be a silent
    # no-op. https://docs.github.com/en/actions/how-tos/manage-runners/
    # self-hosted-runners/run-scripts
    name = "nix-ci-wake-assertion-job-started.sh";
    text = ''
      # THIS HOOK BLOCKS THE JOB AND CAN FAIL IT. GitHub runs it synchronously,
      # and any non-zero exit marks the job failed (`continue-on-error` does not
      # apply). So every path below ends in `exit 0`, and the one long-lived
      # thing it starts is detached with all three fds on /dev/null — an
      # inherited pipe would make the runner wait for EOF instead of starting
      # the job.

      # Find the ancestor whose lifetime IS this job's. Runner.Listener spawns a
      # Runner.Worker per job and the hook runs inside that worker's tree, so the
      # worker is the tightest handle: it exits on completion, cancellation and
      # crash alike. Listener is the fallback (with `--ephemeral` it too exits
      # after one job, just slightly later). Walking the tree rather than
      # `pgrep Runner.Worker` is deliberate — `count = 2` means two workers can
      # be live at once and the wrong one is not a safe guess.
      target=""
      pid=$PPID
      depth=0
      while [ "$pid" -gt 1 ] && [ "$depth" -lt 16 ]; do
        comm=$(/bin/ps -o comm= -p "$pid" 2>/dev/null || true)
        [ -n "$comm" ] || break
        case "''${comm##*/}" in
          Runner.Worker | Runner.Listener)
            target="$pid"
            break
            ;;
        esac
        parent=$(/bin/ps -o ppid= -p "$pid" 2>/dev/null || true)
        parent=''${parent// /}
        [ -n "$parent" ] || break
        pid="$parent"
        depth=$((depth + 1))
      done

      if [ -z "$target" ]; then
        # SAY SO LOUDLY RATHER THAN FAIL. A job that runs unprotected is better
        # than a job that cannot start, but a SILENT regression here looks
        # identical to the bug this hook exists to fix.
        echo "::warning title=No wake assertion::found no Runner.Worker/Runner.Listener ancestor in $depth levels — this job runs with NO idle-sleep guard and macOS may sleep under it"
        exit 0
      fi

      # -i and ONLY -i. `-i` is PreventUserIdleSystemSleep: it keeps the SYSTEM
      # awake on battery as well as AC, which is what `sleep 1` on both power
      # sources needs. Rejected, each for a reason and not by omission:
      #   -s  prevents system sleep, but caffeinate(8) says it "is valid only
      #       when system is running on AC power" — so on battery it would be a
      #       guard that quietly is not there.
      #   -d  prevents DISPLAY sleep. A CI job needs no screen, and holding the
      #       panel lit through a 40-minute build is wasted power.
      #   -u  declares USER ACTIVITY — it turns the display ON, and with no -t
      #       it expires after 5 seconds. It also lies to every other consumer
      #       of user-presence state.
      #   -m  prevents DISK idle sleep. Not what kills a job: real I/O already
      #       resets that timer.
      # No -t: a timeout would be a second number to keep in sync with the
      # longest job anyone ever writes, and -w already ends the assertion on the
      # real event.
      #
      # WHAT THIS DOES NOT COVER, so nobody reads a green job as proof: `-i`
      # blocks IDLE sleep only. A forced sleep still wins — closing the lid, or
      # `pmset sleepnow` — so a closed-lid battery job can still die.
      /usr/bin/caffeinate -i -w "$target" </dev/null >/dev/null 2>&1 &
      caffeinate_pid=$!

      # PROVE IT TOOK. `-w` on a pid that has already exited returns 0
      # immediately, and a backgrounded `&` reports success either way — so
      # without this check "no assertion" and "assertion held" look identical
      # from the job log, which is exactly the shape of the bug being fixed.
      #
      # Absolute paths throughout: this hook takes NO `runtimeInputs`, so its PATH
      # is whatever the runner happens to export. Everything it calls is a macOS
      # system binary that is always there, which is the point — a wake-assertion
      # guard that depends on a job's PATH is a guard that disappears on the job
      # that needed it most.
      #
      # NO PIPE INTO grep, and NOT a style preference. The obvious spelling,
      # `pmset -g assertions | grep -q "pid $caffeinate_pid(caffeinate)"`, is
      # WRONG under this script's `set -o pipefail`: `grep -q` exits at the first
      # match, `pmset` then dies of SIGPIPE, and pipefail turns the whole
      # pipeline non-zero — so the check reports FAILURE precisely when it
      # MATCHED. Measured 2026-10-02 against the built hook: it printed
      # "::warning::… is not holding" while `pmset -g assertions` showed that
      # exact pid holding the assertion. A verifier that cries wolf on the
      # success path is worse than no verifier, so the match is a bash `case`
      # over a captured string — no second process, nothing to SIGPIPE.
      #
      # 2s, not 1s: the assertion is registered by a forked caffeinate a moment
      # after `&` returns, so the sleep is the real race and 1s is the margin
      # this measured at.
      /bin/sleep 2
      assertions=$(/usr/bin/pmset -g assertions 2>/dev/null || true)
      case "$assertions" in
        *"pid $caffeinate_pid(caffeinate)"*)
          echo "holding PreventUserIdleSystemSleep (caffeinate pid $caffeinate_pid) until pid $target exits"
          ;;
        *)
          echo "::warning title=No wake assertion::caffeinate pid $caffeinate_pid is not holding PreventUserIdleSystemSleep for watched pid $target — this job runs with NO idle-sleep guard"
          ;;
      esac
      exit 0
    '';
  };

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
        # `--labels` WITHOUT `--no-default-labels` is additive: GitHub's own
        # {self-hosted, macOS, ARM64} survive alongside cfg.extraLabels. See the
        # `extraLabels` option below for the vocabulary and the flip order.
        text = ''
          export RUNNER_ROOT
          token=$(${lib.getExe mintInstallationToken})
          ${lib.getExe' runner "config.sh"} \
            --unattended \
            --disableupdate \
            --work ${lib.escapeShellArg workDir} \
            --url ${lib.escapeShellArg "https://github.com/${cfg.org}"} \
            --name ${lib.escapeShellArg instanceName} \
            --labels ${lib.escapeShellArg (lib.concatStringsSep "," cfg.extraLabels)} \
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
  options.local.macosGithubRunner = {
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

    # LABEL VOCABULARY — capability, not identity.
    #
    # This lane is BARE METAL: the job runs directly on the Mac, so it sees the
    # operator's nix, cachix and a postgres+pgvector on PATH. The OTHER macOS
    # lane in this fleet (`local.tart.githubRunners.*`, the tart-vms capsule) boots a stock
    # Cirrus guest per job that has NONE of that. Both register into the same
    # org and the same `Default` runner group.
    #
    # GitHub assigns every runner {self-hosted, macOS, ARM64} server-side unless
    # `--no-default-labels` is passed. This lane keeps them; the Tart lane
    # suppresses them and re-declares the same three plus `tart`. So a job
    # asking for `[self-hosted, macOS, ARM64]` matches BOTH — the Tart set is a
    # strict superset — and can land on a guest with no nix at all. Today the
    # only thing distinguishing this lane is the ABSENCE of `tart`, and GitHub
    # has no "must not have label" selector. Hence an explicit POSITIVE
    # discriminator: `nix`.
    #
    # upstream option nix-darwin.services.github-runners.<name>.extraLabels
    # exists (modules/services/github-runner/options.nix:149, rendered as
    # `--labels a,b,c` at service.nix:119, with `--no-default-labels` gated on
    # `noDefaultLabels` at options.nix:160 / service.nix:124) -> mirroring its
    # name AND its additive semantics here, rather than inventing a different
    # spelling. The module itself stays unusable for the reason in this file's
    # header (it hard-asserts `nix.enable`, which Determinate disables).
    #
    # FLIP ORDER for anything that NARROWS this (a `runs-on:` edit, or adding
    # `--no-default-labels`). Runner labels are additive and free; a workflow's
    # `runs-on` is a hard AND-match, so a label that is not live yet silently
    # queues every job forever. This fleet has already been bitten by tags that
    # matched no runner.
    #   1. WIDEN: add the label here, activate, and confirm it is live on an
    #      ONLINE runner for that exact scope
    #      (`gh api /orgs/<org>/actions/runners --jq '.runners[]|{name,status,labels:[.labels[].name]}'`).
    #   2. FLIP consumers ONE repo at a time, watching the first run actually
    #      pick up a runner rather than queue.
    #   3. NARROW last, once no workflow references the old label.
    # Never reverse 1 and 2.
    extraLabels = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      default = [ "nix" ];
      description = ''
        Custom labels added to (never replacing) the {self-hosted, macOS, ARM64}
        set GitHub assigns server-side — `--no-default-labels` is deliberately
        NOT passed, so this is purely additive and cannot orphan an existing
        `runs-on:`. The effective set is therefore
        {self-hosted, macOS, ARM64} ∪ extraLabels.

        `nix` is the toolchain discriminator that tells this bare-metal lane
        apart from the Tart-VM lane (`local.tart.githubRunners.*`), which carries
        `tart` instead. Matching is case-insensitive, so `ARM64` here satisfies
        a job asking for `arm64`.
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
            # A JOB THAT TALKS HTTP NEEDS THIS, and nothing about the runner says it is absent.
            # dontsell-ai/app's deploy registers its functions with Inngest by PUTting the app's
            # serve endpoint. That step failed 2026-09-21 with `curl: command not found` — caught
            # only because the step had just been rewritten to fail loudly; the same call written
            # the old way (`|| true`) would have reported success and left production registered
            # against the WRONG Inngest account. `openssl` was already here for the same family of
            # reasons; `curl` simply never got added beside it.
            curl
            # A JOB THAT PROBES PORTS NEEDS THIS, and its absence does not look like an absence.
            # dontsell-ai/app's e2e job frees stale webServer ports with
            # `lsof -ti tcp:$p 2>/dev/null || true` in a pre-flight AND an always() reaper. With no
            # lsof on this path the redirect ate "command not found", `|| true` ate the status, and
            # both steps passed having checked nothing — for weeks. On 2026-09-21 a cancelled run
            # orphaned its mock server on :5444 and next-server on :3100; the reaper reported
            # success while both stayed alive, and the next run died on "…is already used". The app
            # repo now falls back to /usr/sbin/lsof, so this line is belt to that braces: the next
            # workflow to reach for lsof should simply find it.
            lsof
            openssl
            (postgresql_16.withPackages (p: [ p.pgvector ]))
            nix
            cachix
          ];
          environment = {
            HOME = i.stateDir;
            RUNNER_ROOT = i.stateDir;
            # Holds a host wake assertion for the life of each JOB — see the long
            # note at `wakeAssertionHook`. Set in the DAEMON's environment rather
            # than in the runner's `.env` file because that is the half this
            # module owns: `.env` lives in RUNNER_ROOT, which `runDaemon` wipes
            # on every ephemeral re-registration, and GitHub's docs name the
            # operating-system environment as the other supported source.
            ACTIONS_RUNNER_HOOK_JOB_STARTED = "${wakeAssertionHook}/bin/nix-ci-wake-assertion-job-started.sh";
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
