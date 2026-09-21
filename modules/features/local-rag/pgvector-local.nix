# home-manager module: local.rag.pgvector
#
# Local PostgreSQL + pgvector, as a loopback-only launchd user agent (darwin).
#
# WHY: a real pgvector store for vector-similarity / RAG work, bootstrapped
# with a plain-SQL RAG interface — a `docs` table plus an in-DB `embed(text)`
# function that calls `local.rag.ollama` (modules/ollama-local.nix) over
# loopback HTTP. Same shape as any other Home Manager `launchd.agents` unit —
# bound to 127.0.0.1, started at login (RunAtLoad), kept alive (KeepAlive).
# Nothing listens off-box.
#
# NO SECRETS IN THE STORE: auth is loopback-scoped, password-free.
#   * The SUPERUSER (the macOS login user, created by initdb) is reachable ONLY
#     over the local unix socket via `peer` auth (OS-user == role) — used for
#     bootstrap/admin.
#   * Over TCP (127.0.0.1) ONLY the dedicated non-superuser `role` may connect,
#     ONLY to database `db`, via `trust` (no password). `role` owns `db` and
#     has no rights anywhere else, so a consumer's blast radius is exactly
#     that one database.
# The connection URI therefore carries no secret and is safe to emit into the
# store; it is exposed read-only as `local.rag.pgvector.databaseUri`. This
# module does NOT wire that URI into any MCP server or client itself — that's
# on you: point your own Postgres-backed tool (MCP server, script, whatever)
# at it. See README.md "Security model" + "Install" for the shape.
#
# BOOTSTRAP: the run-wrapper initdb's the data dir on first launch, writes a
# locked-down pg_hba.conf every launch (idempotent), and — once, guarded by a
# sentinel that also tracks the bootstrap SQL's content — creates the `role` +
# `db` + `CREATE EXTENSION vector`, then execs postgres in the foreground for
# launchd to supervise.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.local.rag.pgvector;
  # Ollama's COORDINATES come from home-manager's own `services.ollama`
  # (upstream option home-manager.services.ollama.host/.port exists -> using it;
  # pinned home-manager modules/services/ollama.nix:28-44). The embed MODEL and
  # its dimension are this flake's addition on top, in `local.rag.ollama`.
  ollama = config.services.ollama;
  embed = config.local.rag.ollama;
in
{
  imports = [
    # Single-sources embedModel/embedDim into the bootstrap SQL below — always
    # present even if a consumer only imports this module. (host/port need no
    # import: `services.ollama` is one of home-manager's own base modules.)
    ./ollama-local.nix
  ];

  options.local.rag.pgvector = {
    enable = lib.mkEnableOption "local Postgres + pgvector RAG store as a launchd user agent (darwin)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 5433;
      description = ''
        TCP port Postgres listens on. Defaults off 5432 to avoid clashing
        with a possible Homebrew/other Postgres install.
      '';
    };

    role = lib.mkOption {
      type = lib.types.str;
      default = "mcp";
      description = ''
        Non-superuser role created on bootstrap, scoped to `db` only (owns it,
        no rights elsewhere). This is the role a consumer's connection URI
        authenticates as over TCP.
      '';
    };

    db = lib.mkOption {
      type = lib.types.str;
      default = "ragdb";
      description = "Database created on bootstrap, owned by `role`.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/postgres-pgvector";
      description = "Postgres data directory (initdb target, PGDATA).";
    };

    extraSql = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra SQL appended to the RAG bootstrap and applied under the same
        stamp: it runs as the cluster superuser against `db` whenever the
        combined bootstrap text changes, so it MUST be idempotent
        (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, …).
        This is the seam a private layer fills with domain tables — a
        consumer creating its own table must also GRANT it to `role`
        (the statements run as superuser, so ownership does not default
        to `role` the way `public.docs`'s explicit grants do).
      '';
    };

    extraDatabases = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            db = lib.mkOption {
              type = lib.types.str;
              description = "Database created on bootstrap, owned by `role`.";
            };
            role = lib.mkOption {
              type = lib.types.str;
              description = "Non-superuser role scoped to `db` only, reachable on 127.0.0.1.";
            };
            extensions = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "vector" ];
              description = ''
                Extensions created in `db` AS SUPERUSER on bootstrap. `vector`
                by default: a scoped role cannot `CREATE EXTENSION` itself, so
                a consumer whose migrations assume pgvector would otherwise
                fail on its first run and need a manual superuser step.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        ADDITIONAL loopback databases bootstrapped in this same cluster, each
        with its own scoped role — for consumers that must not share `db`
        (e.g. an app's local dev database next to the RAG store).

        WHY THIS IS AN OPTION AND NOT A MANUAL STEP: the run-wrapper rewrites
        `pg_hba.conf` with a TRUNCATING redirect on EVERY launch, so a
        hand-added entry survives only until the next restart and then the
        consumer gets `no pg_hba.conf entry for host "127.0.0.1"`. Anything
        that needs TCP access has to be declared here. (Diagnosed 2026-09-21,
        after dontsell-ai/app's local dev database lost its hand-added line.)

        Same security model as `db`/`role`: loopback-only, `trust`, each role
        scoped to exactly one database, no secret in the store.
      '';
      example = [
        {
          db = "dontsell_dev";
          role = "dontsell";
        }
      ];
    };

    databaseUri = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "postgresql://${cfg.role}@127.0.0.1:${toString cfg.port}/${cfg.db}";
      description = ''
        Loopback pgvector connection URI. The role is scoped to a single
        database (no secret, trust auth on 127.0.0.1). Wire this into your
        OWN Postgres-backed consumer (e.g. an MCP `postgres` server's
        DATABASE_URI) — this module does not do that wiring for you.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isDarwin) (
    let
      # postgresql WITH pgvector (`CREATE EXTENSION vector`) AND pgsql-http
      # (`CREATE EXTENSION http`) — the latter lets the in-DB embed() function
      # POST to local Ollama.
      pgPkg = pkgs.postgresql_16.withPackages (ps: [
        ps.pgvector
        ps.pgsql-http
      ]);

      # RAG bootstrap SQL, applied to `db` (as superuser) whenever it changes.
      # Makes any plain-SQL client (e.g. an MCP `postgres` server) a complete
      # RAG endpoint:
      #   * `public.embed(text) -> vector` — SECURITY DEFINER, calls local
      #     Ollama over loopback HTTP and returns the embedding. The http
      #     extension lives in a private `ext` schema that `${role}` has NO
      #     access to, so retrieved/untrusted content can't trick an LLM into
      #     arbitrary HTTP via SQL — only this fixed-URL wrapper is exposed.
      #   * `public.docs` — the conventional store (content + jsonb metadata +
      #     a vector(embedDim) column) with an HNSW cosine index.
      # So ingest is `INSERT INTO docs (content, embedding) VALUES ($1, embed($1))`
      # and query is `... ORDER BY embedding <=> embed('question') LIMIT k` —
      # the client never handles vectors directly.
      ragSql = pkgs.writeText "rag-bootstrap.sql" ''
        CREATE EXTENSION IF NOT EXISTS vector;
        CREATE SCHEMA IF NOT EXISTS ext;
        CREATE EXTENSION IF NOT EXISTS http SCHEMA ext;

        CREATE OR REPLACE FUNCTION public.embed(input text) RETURNS public.vector
          LANGUAGE sql
          -- STABLE is load-bearing, not a nicety: without it the function is
          -- VOLATILE (SQL default), so `ORDER BY embedding <=> embed('q')` — the
          -- one retrieval pattern every consumer uses (the `rag` skill, and any
          -- domain table a private layer adds) — re-evaluates embed() PER ROW and the planner
          -- refuses the HNSW index. Measured 2026-09-12 on docs (5,979 rows):
          -- inline embed() seq-scanned in 115,117 ms (one Ollama POST per row);
          -- STABLE makes Postgres evaluate it once and use the index → 132 ms.
          -- STABLE (not IMMUTABLE) is correct: no DB writes, same input → same
          -- vector within a statement, but it depends on an external model.
          STABLE
          SECURITY DEFINER
          SET search_path = pg_temp
        AS $embed$
          SELECT (
            (ext.http_post(
              'http://${ollama.host}:${toString ollama.port}/api/embeddings',
              pg_catalog.json_build_object('model', '${embed.embedModel}', 'prompt', input)::text,
              'application/json'
            )).content::jsonb -> 'embedding'
          )::text::public.vector;
        $embed$;

        CREATE TABLE IF NOT EXISTS public.docs (
          id        bigserial PRIMARY KEY,
          content   text NOT NULL,
          metadata  jsonb NOT NULL DEFAULT '{}',
          embedding public.vector(${toString embed.embedDim})
        );
        CREATE INDEX IF NOT EXISTS docs_embedding_hnsw
          ON public.docs USING hnsw (embedding public.vector_cosine_ops);

        -- Lock the raw http surface away from ${cfg.role}; expose only the
        -- fixed-URL embed().
        REVOKE ALL ON SCHEMA ext FROM PUBLIC;
        GRANT EXECUTE ON FUNCTION public.embed(text) TO ${cfg.role};
        GRANT ALL ON public.docs TO ${cfg.role};
        GRANT USAGE, SELECT ON SEQUENCE public.docs_id_seq TO ${cfg.role};

        -- local.rag.pgvector.extraSql: consumer-supplied idempotent SQL
        -- (domain tables from a private layer). Appended INSIDE this file so
        -- the .rag-sql stamp covers it and edits re-apply on rebuild.
        ${cfg.extraSql}
      '';

      # Stamp for the extra-database spec: the bootstrap block re-runs when
      # this text changes, so adding an entry applies on the next rebuild
      # instead of needing the cluster wiped.
      extraDbSpec = lib.concatMapStrings (
        e: "${e.db}:${e.role}:${lib.concatStringsSep "," e.extensions};"
      ) cfg.extraDatabases;

      runScript = pkgs.writeShellApplication {
        name = "postgres-pgvector-run";
        runtimeInputs = [ pgPkg ];
        text = ''
          DATADIR=${lib.escapeShellArg cfg.dataDir}
          PORT=${toString cfg.port}
          OSUSER="$(id -un)"

          mkdir -p "$DATADIR"
          chmod 700 "$DATADIR"

          # First launch: initialise the cluster (superuser = the login user, socket peer auth).
          if [ ! -s "$DATADIR/PG_VERSION" ]; then
            initdb -D "$DATADIR" -U "$OSUSER" --auth=peer --encoding=UTF8 --no-locale
          fi

          # Loopback-only auth, rewritten every launch (idempotent): superuser via
          # the local socket (peer); over TCP only ${cfg.role}@${cfg.db} (trust, no
          # secret). Nothing else on TCP.
          {
            printf '%s\n' "local   all   all   peer"
            printf '%s\n' "host    ${cfg.db}   ${cfg.role}   127.0.0.1/32   trust"
            printf '%s\n' "host    ${cfg.db}   ${cfg.role}   ::1/128   trust"
            ${lib.concatMapStrings (e: ''
              printf '%s\n' "host    ${e.db}   ${e.role}   127.0.0.1/32   trust"
              printf '%s\n' "host    ${e.db}   ${e.role}   ::1/128   trust"
            '') cfg.extraDatabases}
          } > "$DATADIR/pg_hba.conf"

          # Ensure the scoped role + database + RAG schema. Re-runs when the
          # role/db is missing OR the RAG bootstrap SQL changed (stamp = its store
          # path), so schema edits re-apply on rebuild; otherwise skipped for a
          # fast launch. All idempotent.
          if [ ! -f "$DATADIR/.pgvector-local-bootstrapped" ] \
             || [ "$(cat "$DATADIR/.rag-sql" 2>/dev/null || true)" != "${ragSql}" ] \
             || [ "$(cat "$DATADIR/.extra-dbs" 2>/dev/null || true)" != "${extraDbSpec}" ]; then
            pg_ctl -D "$DATADIR" -w \
              -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=$DATADIR" start
            if ! psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                 "SELECT 1 FROM pg_roles WHERE rolname='${cfg.role}'" | grep -q 1; then
              createuser -h "$DATADIR" -p "$PORT" -U "$OSUSER" ${cfg.role}
            fi
            if [ "$(psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                 "SELECT 1 FROM pg_database WHERE datname='${cfg.db}'")" != "1" ]; then
              createdb -h "$DATADIR" -p "$PORT" -U "$OSUSER" -O ${cfg.role} ${cfg.db}
            fi
            psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d ${cfg.db} -v ON_ERROR_STOP=1 \
              -c "GRANT ALL ON SCHEMA public TO ${cfg.role};" \
              -f ${ragSql}

            # local.rag.pgvector.extraDatabases — same shape as the RAG pair
            # above (scoped role owns exactly one db), unrolled per entry. The
            # extensions run as SUPERUSER: a scoped role cannot CREATE
            # EXTENSION, so a consumer's first migration would otherwise fail.
            ${lib.concatMapStrings (e: ''
              if ! psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                   "SELECT 1 FROM pg_roles WHERE rolname='${e.role}'" | grep -q 1; then
                createuser -h "$DATADIR" -p "$PORT" -U "$OSUSER" ${e.role}
              fi
              if [ "$(psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d postgres -tAc \
                   "SELECT 1 FROM pg_database WHERE datname='${e.db}'")" != "1" ]; then
                createdb -h "$DATADIR" -p "$PORT" -U "$OSUSER" -O ${e.role} ${e.db}
              fi
              psql -h "$DATADIR" -p "$PORT" -U "$OSUSER" -d ${e.db} -v ON_ERROR_STOP=1 \
                -c "GRANT ALL ON SCHEMA public TO ${e.role};" \
                ${lib.concatMapStrings (x: ''-c "CREATE EXTENSION IF NOT EXISTS ${x};" '') e.extensions}
            '') cfg.extraDatabases}
            pg_ctl -D "$DATADIR" -w stop
            touch "$DATADIR/.pgvector-local-bootstrapped"
            printf '%s\n' "${ragSql}" > "$DATADIR/.rag-sql"
            printf '%s\n' "${extraDbSpec}" > "$DATADIR/.extra-dbs"
          fi

          exec postgres -D "$DATADIR" -p "$PORT" \
            -c listen_addresses=127.0.0.1 -c unix_socket_directories="$DATADIR"
        '';
      };
    in
    {
      # Postgres client tools (psql/createdb/…) on PATH for manual queries.
      #
      # This is the fleet's ONLY profile-level postgres, and deliberately so —
      # `modules/shared/home.nix` carried a second, pgvector-only copy until
      # 2026-09-16. It is `withPackages`, so `share/postgresql` carries BOTH
      # `vector.control` and `http.control`: an `initdb` from PATH can
      # `CREATE EXTENSION vector` (which a plain postgresql_16 cannot) and
      # `CREATE EXTENSION http`.
      #
      # SECOND CONSUMER, so do not narrow this to the RAG's own needs: the
      # dontsell-ai/app CI `integration` job needs pgvector whenever it lands on
      # the REPO-level runner (`macos-throwaway`), which runs out of this profile.
      # The ORG runners get their own copy from modules/darwin/github-runner.nix
      # and do not depend on this line. That job therefore rides on
      # `local.rag.pgvector.enable`, which modules/shared/home.nix sets to
      # `isMacosHost` — turning it off on the Mac would break the job.
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
    }
  );
}
