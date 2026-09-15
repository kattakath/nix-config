# home-manager module: local.rag.ollama
#
# The EMBEDDING half of the local RAG stack. Ollama itself is NOT hand-rolled
# here: home-manager already ships `services.ollama`, whose darwin path emits a
# `launchd.agents.ollama` running `ollama serve` with `OLLAMA_HOST` bound from
# its own `host`/`port`, `KeepAlive`, `ProcessType = "Background"`, and
# `home.packages`. This module turns that on and adds the one thing upstream
# has no opinion about — making sure an EMBED model is actually present, since
# nothing in a pgvector store can generate embeddings on its own and
# `local.rag.pgvector` (modules/pgvector-local.nix) calls Ollama over
# loopback HTTP from an in-DB `embed()` function.
#
#   upstream option home-manager.services.ollama exists -> using it
#   (pinned home-manager modules/services/ollama.nix:110-126 — launchd.agents.ollama
#   with EnvironmentVariables/KeepAlive/ProcessType, plus home.packages; options
#   host/port at :28-44; auto-imported by modules/modules.nix:95, which readDir's
#   ./services)
#
# So bind address and port are `services.ollama.host` / `.port` — set them
# there, not here. They stay loopback (127.0.0.1) by upstream default; widening
# them is on you, Ollama has no auth. Extra server env goes through upstream's
# `services.ollama.environmentVariables` (:73), not a wrapper script.
#
# grepped home-manager/modules/services/ollama.nix for pull/model/embed — no
# option exists -> the pull agent below is custom, because upstream's HM module
# models the SERVER only and never fetches a model. (Prior art for the shape:
# NixOS `services.ollama.loadModels`, pinned nixos/modules/services/misc/
# ollama.nix:151-169 — a separate one-shot `ollama-model-loader` unit, which is
# exactly what the pull agent is on launchd.)
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
      the local RAG embedding runtime: home-manager's `services.ollama` plus a
      one-shot agent that pulls `embedModel` (darwin)
    '';

    manageServer = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this capsule stands up the ollama SERVER itself, via
        home-manager's `services.ollama` (a per-user `launchd.agents.ollama`).

        Set false when something else already serves ollama on
        `services.ollama.host`/`.port` — on this fleet that is the machine-wide
        `local.ollamaDaemon` (modules/darwin/ollama-daemon.nix), which exists so
        a SECOND account shares one server and one model store instead of
        duplicating 31 GB per login.

        The rest of the capsule is unaffected: `embedModel` is still pulled, and
        the pull agent still targets host/port — it simply talks to a server it
        no longer owns. Leaving this true alongside the system daemon would put
        two `ollama serve` processes on the same port, where one wins and the
        other flaps under KeepAlive.
      '';
    };

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
      services.ollama.enable = cfg.manageServer;

      # Upstream sets no StandardOutPath, so the server's log would vanish into
      # launchd's sink. Merge the historical path back onto upstream's own
      # agent rather than forking it — `launchd.agents.<name>.config` is a
      # submodule that declares the key.
      # grepped home-manager/modules/services/ollama.nix for Standard*Path — no
      # option exists -> custom, because losing `ollama serve`'s log is an
      # operator-visible regression.
      # (pinned home-manager modules/launchd/default.nix:36 — `config` is
      # `submodule (import ./launchd.nix)`; StandardOutPath at launchd.nix:437)
      #
      # Gated with the server itself: with `manageServer = false` there is no
      # `launchd.agents.ollama` to attach a log path to, and configuring one
      # would resurrect the agent as an empty unit.
      launchd.agents.ollama = lib.mkIf cfg.manageServer {
        config = {
          StandardOutPath = "${logDir}/ollama-local.log";
          StandardErrorPath = "${logDir}/ollama-local.log";
        };
      };

      # One-shot: RunAtLoad, no KeepAlive. A failed pull exits non-zero and
      # stays visible in `launchctl print` and the log below — when this ran
      # inside the old server wrapper it had to be swallowed with `|| true`, or
      # a missing model would have taken `ollama serve` down with it.
      launchd.agents.ollama-local-pull = {
        enable = true;
        config = {
          ProgramArguments = [ (lib.getExe pullScript) ];
          RunAtLoad = true;
          StandardOutPath = "${logDir}/ollama-local-pull.log";
          StandardErrorPath = "${logDir}/ollama-local-pull.log";
        };
      };
    }
  );
}
