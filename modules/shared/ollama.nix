# Local Ollama, as a loopback-only launchd user agent (darwin) — the embedding
# runtime for the RAG stack. Same shape as the postgres/mcp-proxy agents.
#
# WHY: pgvector stores + retrieves vectors, but nothing in the stack GENERATES
# embeddings, and the LLM client cannot embed text itself. Ollama runs an embed
# model (nomic-embed-text, 768-dim) locally — private, free, no API key — and the
# in-DB `embed()` function (modules/shared/postgres-pgvector.nix) calls it over
# loopback HTTP, so the whole RAG loop is plain SQL through the `postgres` MCP
# server (no separate embedding MCP server to spawn/break).
#
# The run-wrapper execs `ollama serve` in the foreground for launchd to supervise,
# and pulls the embed model once in the background after the server is up (skipped
# on later launches once present). Bound to 127.0.0.1 — nothing listens off-box.
#
# The host/port/model/dim are exposed as read-only `services.ollamaLocal.*` options
# so the postgres module single-sources them into `embed()` and the vector column.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  host = "127.0.0.1";
  port = 11434;
  embedModel = "nomic-embed-text";
  embedDim = 768; # nomic-embed-text output dimension

  runScript = pkgs.writeShellApplication {
    name = "ollama-local-run";
    runtimeInputs = [ pkgs.ollama ];
    text = ''
      export OLLAMA_HOST=${host}:${toString port}
      export OLLAMA_MODELS="$HOME/.ollama/models"

      # Pull the embed model once, in the background, after the server accepts calls.
      # Idempotent: skipped on later launches once the model is present.
      (
        for _ in $(seq 1 120); do
          if ollama list >/dev/null 2>&1; then break; fi
          sleep 1
        done
        if ! ollama list 2>/dev/null | grep -q ${embedModel}; then
          ollama pull ${embedModel} || true
        fi
      ) &

      exec ollama serve
    '';
  };
in
{
  options.services.ollamaLocal = {
    host = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = host;
    };
    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      default = port;
    };
    embedModel = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = embedModel;
    };
    embedDim = lib.mkOption {
      type = lib.types.int;
      readOnly = true;
      default = embedDim;
    };
  };

  config = lib.mkIf pkgs.stdenv.isDarwin {
    home.packages = [ pkgs.ollama ];

    launchd.agents.ollama-local = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe runScript) ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/ollama-local.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/ollama-local.log";
      };
    };
  };
}
