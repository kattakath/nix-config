# home-manager module: local.rag.ollama
#
# The EMBEDDING half of the local RAG stack. It does NOT serve Ollama: the one
# `ollama serve` on this fleet is the machine-wide `local.ollamaDaemon`
# (modules/darwin/ollama-daemon.nix), so every account shares one process and
# one model store. This module adds the one thing no server module has an
# opinion about — making sure an EMBED model is actually present, since nothing
# in a pgvector store can generate embeddings on its own and
# `local.rag.pgvector` (./pgvector-local.nix) calls Ollama over loopback HTTP
# from an in-DB `embed()` function.
#
# The server's COORDINATES are home-manager's own `services.ollama.host` /
# `.port` (upstream option exists -> using it, as plain data; its `enable` stays
# off). modules/home/default.nix threads the daemon's host/port into them.
#
# grepped home-manager/modules/services/ollama.nix for pull/model/embed — no
# option exists -> the pull agent below is custom, because upstream's HM module
# models the SERVER only and never fetches a model. (Prior art for the shape:
# NixOS `services.ollama.loadModels`, pinned nixos/modules/services/misc/
# ollama.nix's `systemd.services.ollama-model-loader` — a separate one-shot
# unit, which is exactly what the pull agent is on launchd.)
#
# macOS-ONLY: gated on stdenv.hostPlatform.isDarwin, so enabling it on a Linux host is a
# clean no-op (safe for mixed nix-darwin + NixOS fleets, and for `nix flake
# check` on Linux runners).
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.local.rag.ollama;
  ollama = config.services.ollama;
  logDir = "${config.home.homeDirectory}/Library/Logs";
in
{
  options.local.rag.ollama = {
    enable = lib.mkEnableOption ''
      the local RAG embedding runtime: a one-shot agent that pulls `embedModel`
      into the ollama server at `services.ollama.host`/`.port` (darwin)
    '';

    embedModel = lib.mkOption {
      type = lib.types.str;
      default = "nomic-embed-text";
      description = ''
        Ollama model pulled (once, by the one-shot agent) and used for
        embeddings. Must match `local.rag.ollama.embedDim` below for
        whatever model you choose — `nomic-embed-text` is 768-dim.
      '';
    };

    embedDim = lib.mkOption {
      type = lib.types.int;
      default = 768;
      description = ''
        Output dimension of `embedModel`. Consumed by
        `local.rag.pgvector` to size the `vector(...)` column — must match
        the model above, or `embed()` calls will fail with a dimension
        mismatch.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) (
    let
      pullScript = pkgs.writeShellApplication {
        name = "ollama-local-pull";
        runtimeInputs = [ ollama.package ];
        text = ''
          export OLLAMA_HOST=${ollama.host}:${toString ollama.port}

          # launchd has no ordering between agents, so poll instead of assuming
          # `ollama serve` won the race. Falling out of the loop is fine: the
          # pull below then fails loudly rather than pretending it worked.
          for _ in $(seq 1 120); do
            if ollama list >/dev/null 2>&1; then break; fi
            sleep 1
          done

          # Bash substring match, NOT `ollama list | grep -q`: under
          # `writeShellApplication`'s `pipefail`, grep -q exiting early can
          # SIGPIPE `ollama list` (141), which reads as "model absent" and
          # re-pulls on every login. Idempotent as written.
          models=$(ollama list 2>/dev/null || true)
          want=${lib.escapeShellArg cfg.embedModel}
          if [[ $models != *"$want"* ]]; then
            ollama pull "$want"
          fi
        '';
      };
    in
    {
      # Retry-until-success, using launchd's own keys rather than a second retry
      # loop of ours.
      #
      # This was RunAtLoad with no KeepAlive, on the reasoning that a failed pull
      # "stays visible". It did — and then stayed FAILED for the whole login
      # session. Measured 2026-09-22: `runs = 1, last exit code = 1`, and ten
      # consecutive "could not connect to ollama server" lines in the log below.
      #
      # Note what that does NOT mean: the `ollama list` poll loop in `pullScript`
      # already waits 120 x 1s for
      # the server, so this is not a missing wait. It is a pull that exhausted a
      # two-minute budget on a cold login — the machine-wide daemon
      # (`local.ollamaDaemon`) was still coming
      # up — and then had no second chance until the next login.
      #
      # KeepAlive.SuccessfulExit = false is launchd's "restart until it exits 0",
      # which is exactly the semantic wanted, and the same Lego media-cli's queue
      # already uses (modules/features/media-cli/module.nix's `KeepAlive.SuccessfulExit = false`). ThrottleInterval
      # raises launchd's flat ~10s respawn floor to a minute, because a model pull
      # is not something to retry ten times a minute. The `ollama list` poll loop in
      # `pullScript` STAYS: it is
      # what makes the common case succeed in a single spawn, so removing it would
      # turn every cold login into a throttled respawn.
      #
      # Cost, accepted: a pull that can never succeed (genuinely offline, or a
      # renamed model) now retries every 60s instead of failing once, so the log
      # below grows. That log is in the newsyslog rotation set for exactly this
      # reason.
      launchd.agents.ollama-local-pull = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe pullScript) ];
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
          ThrottleInterval = 60;
          StandardOutPath = "${logDir}/ollama-local-pull.log";
          StandardErrorPath = "${logDir}/ollama-local-pull.log";
        };
      };
    }
  );
}
