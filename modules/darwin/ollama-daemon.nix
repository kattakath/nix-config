# Ollama as a SYSTEM daemon, shared by every account on the Mac.
#
# WHY A DAEMON AND NOT THE PER-USER AGENT. home-manager's `services.ollama`
# emits `launchd.agents.ollama`, which lives inside ONE user's GUI session: it
# starts at that user's login and its models sit in that user's home — so the
# server exists only while that one account happens to be logged in, and any
# further account on the machine would need its own 31 GB model store. A system
# daemon has neither problem: one process, one model store, up from boot and
# reachable on loopback by whoever is logged in.
#
# upstream-first: grepped the pinned nix-darwin for an ollama service —
# `modules/services/` has NO ollama.nix and the string appears nowhere under
# `modules/`. Nothing models this, so the daemon is genuinely custom. It is
# still built on nix-darwin's own `launchd.daemons` primitive
# (modules/launchd/default.nix:155), not a hand-rolled plist.
#
# The `launchd-naming` rule's load-bearing half does not apply: that rule exists
# so an adhoc-signed /nix/store arg0 keeps TCC read access to ~/Desktop,
# ~/Documents and ~/Downloads. This daemon runs as root against
# `modelsPath` under /var/lib and reads none of those.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.local.ollamaDaemon;
in
{
  options.local.ollamaDaemon = {
    enable = lib.mkEnableOption ''
      a machine-wide `ollama serve` on loopback, so every account shares one
      server and one model store instead of one per login
    '';

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Bind address. Stays on LOOPBACK deliberately: a shared server is still
        a local one, and `0.0.0.0` would expose an unauthenticated model
        runtime to the network. Every consumer on this Mac reaches it over
        loopback regardless of which user they run as.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 11434;
      description = ''
        Ollama's own default. Consumers key off `local.mediaCli.ollamaHost`,
        whose default is already `127.0.0.1:11434`, so leaving this alone means
        nothing else needs configuring.
      '';
    };

    modelsPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ollama/models";
      description = ''
        Shared model store, outside any user's home — that is the whole point.
        /var/lib matches the fleet's other system daemon
        (`modules/darwin/github-runner.nix` uses /var/lib/github-runner-*).

        Moving an existing store here is a RENAME, not a copy: /Users and
        /private/var are firmlinked onto the same APFS data volume, so 31 GB
        relocates instantly.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ollama;
      defaultText = lib.literalExpression "pkgs.ollama";
      description = "The ollama build the daemon serves from.";
    };

    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # THE POWER BUDGET, and it is measured, not guessed. This Mac charges at
        # 35 W; one generation draws about 10 W, so the safe configuration is
        # "never more than one resident runner and never more than one request
        # in flight". Raising either of these is how a describe burst starts
        # outrunning the charger.
        #
        # These moved here from `services.ollama.environmentVariables` in
        # modules/shared/home.nix when the server became a daemon. They HAD to
        # move: that option only reaches home-manager's own agent, so once the
        # capsule stopped managing the server the whole block went inert —
        # declared, evaluated, and reaching nothing. Keep the fact in ONE place,
        # next to the process it configures.
        # WHY 1, and not a round number: a 6.1 GB vision model IS the whole GPU.
        # photo-describe serialises within a run, but that lock covers the
        # WORKER only — a hand-run `photo-describe` alongside a draining queue,
        # or `qwen` mid-sweep, would otherwise put two inferences on one GPU.
        # Ollama queues rather than thrashes, so the failure mode is slow rather
        # than broken; this states the constraint where the resource actually
        # is, instead of in one of its callers. Now that a SECOND account can
        # reach this server, the argument is stronger, not weaker.
        OLLAMA_MAX_LOADED_MODELS = "1";
        # Read by `ollama serve`, never by clients, so it cannot be set through
        # a shell variable — a login shell's environment never reaches a
        # launchd-started daemon.
        OLLAMA_NUM_PARALLEL = "1";
        # A bounded unload timer is a SAFETY NET, not an optimisation: the
        # idle-burn bug class (ollama#2129, #13232) is filed against qwen3-vl
        # variants, which is exactly the vision model this fleet runs. 10m keeps
        # batch describe runs warm between bursts while still guaranteeing an
        # idle Mac lets go of the GPU.
        OLLAMA_KEEP_ALIVE = "10m";
      };
      description = ''
        Extra environment for `ollama serve`. `OLLAMA_HOST` and
        `OLLAMA_MODELS` are set from the options above and always win, so this
        is for tuning only.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) {
    # The store directory must exist before the daemon's first run, and it must
    # NOT be recreated under a user's ownership — root owns it, and clients only
    # ever reach the models through HTTP, never the filesystem. So 0755 is
    # enough: no client needs read access to the blobs.
    system.activationScripts.postActivation.text = lib.mkBefore ''
      mkdir -p ${lib.escapeShellArg cfg.modelsPath}
    '';

    launchd.daemons.ollama = {
      # `command`, NOT `ProgramArguments`, and that is the boot-ordering
      # exception in .claude/rules/launchd-naming.md — not a style choice.
      #
      # /nix is a separate `noauto` APFS volume that determinate-nixd mounts
      # DURING boot. A daemon with RunAtLoad whose arg0 is a store path loses
      # that race, launchd logs "Missing executable" and exits 78 EX_CONFIG, and
      # it then NEVER self-heals: the retry is parked on an "Executable
      # appearance" event that a volume mount does not fire. Measured on this
      # machine, the github-runner daemons sat dead that way for 10h52m, and a
      # `darwin-rebuild switch` did not recover them. No launchd setting fixes
      # it — StartInterval, KeepAlive and KeepAlive.PathState were each measured
      # NOT to retry a failed exec.
      #
      # nix-darwin's own `command` (modules/launchd/default.nix:90-94) emits
      # `/bin/sh -c '/bin/wait4path /nix/store && exec …'`, which is the same
      # shape activate-system and activate-agenix use for the same reason.
      #
      # The rule's load-bearing half — an adhoc-signed store arg0 keeping TCC
      # read access to ~/Desktop, ~/Documents and ~/Downloads — does not apply:
      # this runs as root and touches only /var/lib/ollama. Only BTM legibility
      # is lost, and the process after exec is still `ollama`.
      command = "${cfg.package}/bin/ollama serve";
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;

        # Same power brake the per-user agent carried. `ollama serve` will take
        # every CPU thread it is given; Background QoS is what keeps a
        # generation inside the charger's budget on battery rather than
        # spiking the package power.
        ProcessType = "Background";

        # Tuning first, then the two the module owns — so host/models cannot be
        # overridden out from under the daemon by an `environmentVariables` entry.
        EnvironmentVariables = cfg.environmentVariables // {
          OLLAMA_HOST = "${cfg.host}:${toString cfg.port}";
          OLLAMA_MODELS = cfg.modelsPath;
          # ollama writes non-model state (history, keys) next to HOME. Without
          # this it would land in /var/root, which is both wrong and invisible.
          HOME = builtins.dirOf cfg.modelsPath;
        };

        StandardOutPath = "/var/log/ollama-daemon.log";
        StandardErrorPath = "/var/log/ollama-daemon.log";
      };
    };
  };
}
