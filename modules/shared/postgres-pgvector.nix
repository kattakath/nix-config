# Local PostgreSQL + pgvector, as a loopback-only launchd user agent (darwin).
#
# WHY: backs the `postgres` MCP server in the gateway (modules/shared/mcp.nix) with
# a real pgvector store for vector-similarity / RAG work. Same shape as the mcp-proxy
# gateway agent — a Home Manager `launchd.agents` unit bound to 127.0.0.1, started at
# login (RunAtLoad) and kept alive (KeepAlive). Nothing listens off-box.
#
# NO SECRETS IN THE STORE: auth is loopback-scoped, password-free.
#   * The SUPERUSER (the macOS login user, created by initdb) is reachable ONLY over
#     the local unix socket via `peer` auth (OS-user == role) — used for bootstrap/admin.
#   * Over TCP (127.0.0.1) ONLY the dedicated non-superuser role `mcp` may connect, ONLY
#     to database `ragdb`, via `trust` (no password). `mcp` owns `ragdb` and has no rights
#     anywhere else, so the MCP server's blast radius is exactly that one database.
# The connection URI therefore carries no secret and is safe to emit into the store; it is
# exposed as `services.pgvectorGateway.databaseUri` for mcp.nix to consume (single source).
#
# BOOTSTRAP: the run-wrapper initdb's the data dir on first launch, writes a locked-down
# pg_hba.conf every launch (idempotent), and — once, guarded by a sentinel — creates the
# `mcp` role + `ragdb` database + `CREATE EXTENSION vector`, then execs postgres in the
# foreground for launchd to supervise.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  # postgresql WITH pgvector (`CREATE EXTENSION vector`) AND pgsql-http (`CREATE
  # EXTENSION http`) — the latter lets the in-DB embed() function POST to local Ollama.
  pgPkg = pkgs.postgresql_16.withPackages (ps: [
    ps.pgvector
    ps.pgsql-http
  ]);

  # Non-standard port to avoid clashing with a possible Homebrew/other postgres on 5432.
  port = 5433;
  role = "mcp"; # non-superuser, owns ragdb only
  db = "ragdb";
  dataDir = "${config.home.homeDirectory}/.local/share/postgres-pgvector";

  # Local Ollama coordinates (single-sourced from modules/shared/ollama.nix).
  ollama = config.services.ollamaLocal;

  # RAG bootstrap SQL, applied to `ragdb` (as superuser) whenever it changes. Makes the
  # `postgres` MCP server a complete RAG endpoint via plain SQL:
  #   * `public.embed(text) -> vector` — SECURITY DEFINER, calls local Ollama over loopback
  #     HTTP and returns the embedding. The http extension lives in a private `ext` schema
  #     that `${role}` has NO access to, so retrieved/untrusted content can't trick the LLM
  #     into arbitrary HTTP via SQL — only this fixed-URL wrapper is exposed to `${role}`.
  #   * `public.docs` — the conventional store (content + jsonb metadata + a
  #     vector(${toString ollama.embedDim}) column) with an HNSW cosine index.
  # So ingest is `INSERT INTO docs (content, embedding) VALUES ($1, embed($1))` and query is
  # `... ORDER BY embedding <=> embed('question') LIMIT k` — the client never handles vectors.
  ragSql = pkgs.writeText "rag-bootstrap.sql" ''
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE SCHEMA IF NOT EXISTS ext;
    CREATE EXTENSION IF NOT EXISTS http SCHEMA ext;

    CREATE OR REPLACE FUNCTION public.embed(input text) RETURNS public.vector
      LANGUAGE sql
      SECURITY DEFINER
      SET search_path = pg_temp
    AS $embed$
      SELECT (
        (ext.http_post(
          'http://${ollama.host}:${toString ollama.port}/api/embeddings',
          pg_catalog.json_build_object('model', '${ollama.embedModel}', 'prompt', input)::text,
          'application/json'
        )).content::jsonb -> 'embedding'
      )::text::public.vector;
    $embed$;

    CREATE TABLE IF NOT EXISTS public.docs (
      id        bigserial PRIMARY KEY,
      content   text NOT NULL,
      metadata  jsonb NOT NULL DEFAULT '{}',
      embedding public.vector(${toString ollama.embedDim})
    );
    CREATE INDEX IF NOT EXISTS docs_embedding_hnsw
      ON public.docs USING hnsw (embedding public.vector_cosine_ops);

    -- Lock the raw http surface away from ${role}; expose only the fixed-URL embed().
    REVOKE ALL ON SCHEMA ext FROM PUBLIC;
    GRANT EXECUTE ON FUNCTION public.embed(text) TO ${role};
    GRANT ALL ON public.docs TO ${role};
    GRANT USAGE, SELECT ON SEQUENCE public.docs_id_seq TO ${role};
  '';

  runScript = pkgs.writeShellApplication {
    name = "postgres-pgvector-run";
    runtimeInputs = [ pgPkg ];
    text = ''
      DATADIR=${lib.escapeShellArg dataDir}
      PORT=${toString port}
      OSUSER="$(id -un)"

      mkdir -p "$DATADIR"
      chmod 700 "$DATADIR"

      # First launch: initialise the cluster (superuser = the login user, socket peer auth).
      if [ ! -s "$DATADIR/PG_VERSION" ]; then
        initdb -D "$DATADIR" -U "$OSUSER" --auth=peer --encoding=UTF8 --no-locale
      fi

      # Loopback-only auth, rewritten every launch (idempotent): superuser via the local
      # socket (peer); over TCP only ${role}@${db} (trust, no secret). Nothing else on TCP.
      {
        printf '%s\n' "local   all   all   peer"
        printf '%s\n' "host    ${db}   ${role}   127.0.0.1/32   trust"
        printf '%s\n' "host    ${db}   ${role}   ::1/128   trust"
      } > "$DATADIR/pg_hba.conf"

      # Ensure the scoped role + database + RAG schema. Re-runs when the role/db is
      # missing OR the RAG bootstrap SQL changed (stamp = its store path), so schema
      # edits re-apply on rebuild; otherwise skipped for a fast launch. All idempotent.
      if [ ! -f "$DATADIR/.mcp-bootstrapped" ] \
         || [ "$(cat "$DATADIR/.rag-sql" 2>/dev/null || true)" != "${ragSql}" ]; then
        pg_ctl -D "$DATADIR" -w \
          -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=$DATADIR" start
        if ! psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
             "SELECT 1 FROM pg_roles WHERE rolname='${role}'" | grep -q 1; then
          createuser -h "$DATADIR" -p "$PORT" -U "$OSUSER" ${role}
        fi
        if [ "$(psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
             "SELECT 1 FROM pg_database WHERE datname='${db}'")" != "1" ]; then
          createdb -h "$DATADIR" -p "$PORT" -U "$OSUSER" -O ${role} ${db}
        fi
        psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d ${db} -v ON_ERROR_STOP=1 \
          -c "GRANT ALL ON SCHEMA public TO ${role};" \
          -f ${ragSql}
        pg_ctl -D "$DATADIR" -w stop
        touch "$DATADIR/.mcp-bootstrapped"
        printf '%s\n' "${ragSql}" > "$DATADIR/.rag-sql"
      fi

      exec postgres -D "$DATADIR" -p "$PORT" \
        -c listen_addresses=127.0.0.1 -c unix_socket_directories="$DATADIR"
    '';
  };
in
{
  options.services.pgvectorGateway.databaseUri = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "postgresql://${role}@127.0.0.1:${toString port}/${db}";
    description = ''
      Loopback pgvector connection URI. The role is scoped to a single database
      (no secret, trust auth on 127.0.0.1). Consumed by modules/shared/mcp.nix as
      the `postgres` MCP server's DATABASE_URI.
    '';
  };

  config = lib.mkIf pkgs.stdenv.isDarwin {
    # Put the postgres client tools (psql/createdb/…) on PATH for manual queries.
    home.packages = [ pgPkg ];

    launchd.agents.postgres-pgvector = {
      enable = true;
      config = {
        ProgramArguments = [ (lib.getExe runScript) ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/postgres-pgvector.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/postgres-pgvector.log";
      };
    };
  };
}
