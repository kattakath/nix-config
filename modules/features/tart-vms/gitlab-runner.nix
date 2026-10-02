# local.tart.gitlabRunner — a declarative gitlab-runner (custom executor → ephemeral
# Tart VM per job, via packages/gitlab-tart.nix's slot shims) as a GUI-session
# LaunchAgent.
#
# Why not nix-darwin's own services.gitlab-runner (it exists —
# modules/services/gitlab-runner.nix): it runs a launchd DAEMON under a
# dedicated `gitlab-runner` service user, and Tart guests can only boot in the
# GUI login user's session (Virtualization.framework needs the unlocked
# data-protection keychain — same constraint as local.tart.runners); its `script =`
# also execs a bare-`sh` arg0, and its registration flow is the legacy
# REGISTRATION_TOKEN model, not the modern glrt- authentication token.
#
# Secret delivery is the CONSUMER's job, same contract as local.tart.githubRunners:
# `tokenFile` points at a runtime file holding ONLY the glrt- runner token
# (agenix output, manual install, …) — no token material transits Nix. The
# config.toml is rendered AT AGENT START into ~/.config/nix-gitlab-runner/
# (0700/0600 via umask), so the token never touches the world-readable store.
# Registration itself (minting the glrt- token) stays a one-time manual act.
#
# TAGS ARE NOT DECLARABLE FROM NIX — deliberately absent, not forgotten. Under
# the glrt- authentication-token model a runner's tag_list is server-side
# state, fixed at registration and edited only through the API/UI
# (`PUT /api/v4/runners/:id --data "tag_list=macos,arm64"`); config.toml has no
# tags key to render, and the legacy `--tag-list` belonged to the dead
# REGISTRATION_TOKEN flow. So tags are manual for exactly the same reason
# minting the token is — same one-time act, same place to do it. GitHub's lanes
# (local.tart.githubRunners, and nix-config's local.macosGithubRunner) are the
# opposite: labels ARE declared in Nix and applied at every re-registration.
#
# GitLab matches a job's `tags:` as a subset of the runner's tag_list, same
# AND-semantics as GitHub's `runs-on:` — so the same flip order applies, and
# the API edit takes the place of step 1's activation: widen the runner's
# tag_list first, confirm it on the ONLINE runner (`glab api /runners/:id`),
# flip consumers one project at a time, narrow last.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.tart.gitlabRunner;
  tartCfg = config.local.tart;
  gitlabTart = pkgs.callPackage ./packages/gitlab-tart.nix { };

  # NOT `nix-gitlab-runner`: the agent below sets
  # `launcher.name = "nix-gitlab-runner"`, so home-manager builds a launcher
  # script of that name and THAT is the arg0 launchd execs. Naming this one the
  # same would produce `nix-gitlab-runner` exec'ing `nix-gitlab-runner` — two
  # store paths, one name (the trap modules/home/metube.nix records).
  runner = pkgs.writeShellApplication {
    name = "gitlab-runner-run";
    runtimeInputs = [
      cfg.package
      pkgs.coreutils
    ];
    text = ''
      umask 077

      # Slot-semaphore knobs for the nix-gitlab-tart-* shims (inherited by the
      # custom-executor children); shared with the GitHub local.tart.runners lane.
      export TR_SLOTS_DIR=${lib.escapeShellArg "${tartCfg.runnerStateDir}/slots"}
      export TR_SLOTS_MAX=${toString tartCfg.runnerSlots}

      # EXISTENCE is already handled by launchd (KeepAlive.PathState below), so
      # there is no wait-for-the-file loop here. CONTENT is not something
      # PathState can see: an EMPTY /run/agenix secret satisfies it and then
      # yields a launchd-healthy agent that logs "Runner token is empty or
      # whitespace; this runner will be skipped during job polling" once and
      # then polls nothing, forever. So fail CLOSED on empty.
      token=""
      until [ -n "$token" ]; do
        token="$(tr -d '[:space:]' < ${lib.escapeShellArg cfg.tokenFile} 2>/dev/null || true)"
        if [ -z "$token" ]; then
          echo "nix-gitlab-runner: waiting for a NON-EMPTY token in ${cfg.tokenFile}" >&2
          sleep 5
        fi
      done

      confDir="''${HOME}/.config/nix-gitlab-runner"
      mkdir -p "$confDir"
      cat > "$confDir/config.toml" <<EOF
      concurrent = ${toString cfg.concurrent}
      check_interval = 0
      shutdown_timeout = 0

      [[runners]]
        name = ${builtins.toJSON cfg.runnerName}
        url = ${builtins.toJSON cfg.url}
        token = "$token"
      ${lib.optionalString (cfg.runnerId != null) "  id = ${toString cfg.runnerId}"}
        executor = "custom"
        [runners.feature_flags]
          FF_RESOLVE_FULL_TLS_CHAIN = false
        [runners.custom]
          config_exec = "${gitlabTart.configShim}/bin/nix-gitlab-tart-config"
          prepare_exec = "${gitlabTart.prepare}/bin/nix-gitlab-tart-prepare"
          run_exec = "${gitlabTart.run}/bin/nix-gitlab-tart-run"
          cleanup_exec = "${gitlabTart.cleanup}/bin/nix-gitlab-tart-cleanup"
      ${lib.optionalString (
        cfg.defaultImage != null
      ) "    prepare_args = [ \"--default-image\", ${builtins.toJSON cfg.defaultImage} ]"}
      EOF

      exec gitlab-runner run --config "$confDir/config.toml" --working-directory "$HOME"
    '';
  };
in
{
  # Shares local.tart.runnerSlots / local.tart.runnerStateDir with the GitHub lane (the
  # module system dedupes the double import when a consumer lists both lanes).
  imports = [ ./slots.nix ];

  options.local.tart.gitlabRunner = {
    enable = lib.mkEnableOption "declarative gitlab-runner with the Tart custom executor";
    url = lib.mkOption {
      type = lib.types.str;
      default = "https://gitlab.com/";
      description = "GitLab instance URL.";
    };
    runnerName = lib.mkOption {
      type = lib.types.str;
      description = "The runner's registered name (cosmetic; identity is the token).";
    };
    runnerId = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "The runner id GitLab assigned at registration (optional metadata).";
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path to a file holding ONLY the glrt- runner authentication token.";
    };
    concurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Global job concurrency; may exceed the VM budget — the slot shims serialize.";
    };
    defaultImage = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "ghcr.io/cirruslabs/macos-runner@sha256:<digest>";
      description = ''
        Tart image for a job whose .gitlab-ci.yml names no `image:`, passed to
        gitlab-tart-executor's prepare stage as `--default-image` through
        gitlab-runner's own `prepare_args`. Without it, such a job fails in
        prepare as runner_system_failure, with the executor's misleading
        "CUSTOM_ENV_CI_JOB_ID is missing and no --default-image was set".
        Pin by digest, as the GitHub lane does: a tag would move under the job.
      '';
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.gitlab-runner;
      defaultText = "pkgs.gitlab-runner";
    };
  };

  config = lib.mkIf cfg.enable {
    # CLI on PATH for verify/status against the SAME rendered config.
    environment.systemPackages = [ cfg.package ];

    # RE-REGISTERED BY HAND, because the lane change below dropped it.
    # Pinned nix-darwin modules/launchd/default.nix:199 maps every
    # `launchd.user.agents` entry into `system.requiresPrimaryUser`, and
    # modules/system/primary-user.nix:36-59 turns that list into the guided
    # "set system.primaryUser to the name of the user you have been using to
    # run darwin-rebuild" assertion. Leaving `launchd.user.agents` therefore
    # loses the MESSAGE — not the guarantee: ./slots.nix's `runnerStateDir`
    # default still forces `config.system.primaryUserHome`, whose own default
    # (primary-user.nix:24-25) interpolates `config.system.primaryUser` and so
    # coerces null to a string. That is an uncatchable eval error naming an
    # INTERNAL option, which is a worse thing for a consumer to read than
    # upstream's own prose — so the registration is restated here rather than
    # written off. Upstream's mechanism, upstream's message, one line.
    system.requiresPrimaryUser = [ "local.tart.gitlabRunner" ];

    # Same durable-state mkdir as the GitHub lane, declared here too because
    # neither module may read the other's options (this one never declares
    # local.tart.githubRunners). `mkdir -p` is idempotent and preActivation.text is
    # a lines option, so both declaring it merges cleanly. preActivation is still
    # the right hook after the 2026-10-02 lane change, for a slightly different
    # reason: home-manager's darwin module runs its activation (which loads this
    # agent and opens StandardOutPath below) from `postActivation`, and pinned
    # nix-darwin modules/system/activation-scripts.nix orders preActivation :114
    # before postActivation :140.
    system.activationScripts.preActivation.text = lib.mkAfter ''
      sudo --user=${config.system.primaryUser} -- /bin/mkdir -p ${lib.escapeShellArg tartCfg.runnerStateDir}
    '';

    # ---- THE SELF-HEALING LANE (moved off launchd.user.agents 2026-10-02) ----
    #
    # This was `launchd.user.agents.gitlab-runner` until finding #14. Both layers
    # put a user agent in ~/Library/LaunchAgents under gui/<uid>; only one
    # REPAIRS it, and modules/darwin/launchd-sources.nix enumerates which:
    # nix-darwin's activation is diff-gated in BOTH lanes (pinned nix-darwin
    # modules/system/launchd.nix:19 and :37 wrap the bodies in
    # `if ! diff <old> <new>`), so an UNCHANGED plist means the
    # unload/copy/load body never runs and a unit macOS has dropped stays down.
    # Home Manager PROBES instead: pinned home-manager
    # modules/launchd/default.nix:445-452 takes the `cmp -s` "unchanged" branch
    # and still asks `agentIsLoaded` (:326-331, a `launchctl print
    # <domain>/<agentName>`), falling through to bootout + install + bootstrap on
    # "up-to-date but not loaded".
    #
    # WHY FROM A nix-darwin MODULE and not a home-manager one. The precedent is
    # modules/darwin/logging.nix:337, which declares its user tick exactly this
    # way. It is what keeps the capsule ONE module per lane: `runnerStateDir`'s
    # default reads nix-darwin's `config.system.primaryUserHome` (./slots.nix),
    # the state-dir mkdir above needs `config.system.primaryUser`, and
    # `environment.systemPackages` is a nix-darwin option — so the module has to
    # be a nix-darwin module regardless. A second, home-manager-class module
    # exported through `capsuleModules.homeManager` would have to re-derive this
    # plist from an internal option, and a consumer importing only the darwin
    # half would lose the agent SILENTLY. This way a consumer with no
    # home-manager fails loudly on the option not existing.
    #
    # THE LABEL IS PINNED to its live on-disk value. Home Manager's default is
    # `org.nix-community.home.<name>` (:114, a `lib.mkDefault`, documented at
    # :254), which would be a DIFFERENT launchd unit — the old plist abandoned
    # and the operator's "Allow in the Background" approval, which Background
    # Task Management keys to the Label, silently dropped. The override is safe
    # because the self-heal probe keys off the Label too: :165 names each plist
    # after the unit's own Label and :426 reads `agentName` straight back out of
    # that filename.
    #
    # `enable = true` IS REQUIRED and its absence is SILENT: it is a
    # `mkEnableOption` defaulting to FALSE (:20) and `agentPlists` filters on it
    # (:166), where `launchd.user.agents` had no such switch. An agent declared
    # without it evaluates clean and renders NO plist at all.
    #
    # `waitForNixStore`/`launcher.*` are set EXPLICITLY, not left to
    # modules/home/launchd-launcher.nix's `mkDefault`s: that module is part of
    # THIS fleet's home profile, and a capsule may not assume its consumer loads
    # it. Upstream's default would wrap the command in
    # `/bin/sh -c "/bin/wait4path /nix/store && exec …"` (:112-117), i.e. a bare
    # `sh` arg0 — what .claude/rules/launchd-naming.md forbids. With
    # `waitForNixStore = false` the arg0 becomes a store-resident launcher named
    # `nix-gitlab-runner` (:99-104, :119), which is the SAME basename launchd and
    # BTM saw before this move.
    home-manager.users.${config.system.primaryUser}.launchd.agents.gitlab-runner = {
      enable = true;
      waitForNixStore = false;
      launcher = {
        name = "nix-gitlab-runner";
        shell = pkgs.runtimeShell;
      };
      config = {
        Label = "org.nixos.gitlab-runner";
        ProgramArguments = [ "${runner}/bin/gitlab-runner-run" ];
        RunAtLoad = true;
        # TWO GATES, because they catch different failures and neither covers
        # the other.
        #
        # Waiting for the runtime token file is launchd's job, not a shell
        # poll's: upstream option
        # home-manager.launchd.agents.<name>.config.KeepAlive.PathState exists
        # (pinned home-manager modules/launchd/launchd.nix:227 — nullOr
        # (attrsOf bool), "the job will be kept alive as long as the path
        # exists ... the intent of this feature is that two or more jobs may
        # create semaphores in the file-system namespace") → using it. Before
        # the consumer materializes the token the agent simply stays down; the
        # moment it lands launchd starts us. Restart-on-crash is unchanged —
        # the path outlives any one `gitlab-runner run`.
        #
        # CONTENT is not something PathState can see: an EMPTY /run/agenix
        # secret satisfies PathState and then yields a launchd-healthy agent
        # that logs "Runner token is empty or whitespace; this runner will be
        # skipped during job polling" once and polls nothing, forever. That is
        # why the non-empty wait in `runner` above exists alongside this.
        KeepAlive.PathState = {
          "${cfg.tokenFile}" = true;
        };
        ProcessType = "Background";
        StandardOutPath = "${tartCfg.runnerStateDir}/gitlab-runner.log";
        StandardErrorPath = "${tartCfg.runnerStateDir}/gitlab-runner.log";
      };
    };
  };
}
