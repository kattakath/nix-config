# Ollama as a SYSTEM daemon, shared by every account on the Mac.
#
# WHY A DAEMON AND NOT THE PER-USER AGENT. home-manager's `services.ollama`
# emits `launchd.agents.ollama`, which lives inside ONE user's GUI session: it
# starts at that user's login and its models sit in that user's home. With a
# second account on the machine (hosts/macos.nix `users.users.izzy`) that shape
# forces a choice between two bad outcomes — a second 31 GB model store, or a
# server that only exists while the operator happens to be logged in. A system
# daemon has neither problem: one process, one model store, reachable on
# loopback by whoever is logged in.
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
      serviceConfig = {
        ProgramArguments = [
          "${cfg.package}/bin/ollama"
          "serve"
        ];
        RunAtLoad = true;
        KeepAlive = true;

        # Same power brake the per-user agent carried. `ollama serve` will take
        # every CPU thread it is given; Background QoS is what keeps a
        # generation inside the charger's budget on battery rather than
        # spiking the package power.
        ProcessType = "Background";

        EnvironmentVariables = {
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
