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
  # postgresql WITH pgvector on its extension path (so `CREATE EXTENSION vector` resolves).
  pgPkg = pkgs.postgresql_16.withPackages (ps: [ ps.pgvector ]);

  # Non-standard port to avoid clashing with a possible Homebrew/other postgres on 5432.
  port = 5433;
  role = "mcp"; # non-superuser, owns ragdb only
  db = "ragdb";
  dataDir = "${config.home.homeDirectory}/.local/share/postgres-pgvector";

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

      # One-time: create the scoped role + database + pgvector extension.
      if [ ! -f "$DATADIR/.mcp-bootstrapped" ]; then
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
          -c "CREATE EXTENSION IF NOT EXISTS vector;" \
          -c "GRANT ALL ON SCHEMA public TO ${role};"
        pg_ctl -D "$DATADIR" -w stop
        touch "$DATADIR/.mcp-bootstrapped"
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
