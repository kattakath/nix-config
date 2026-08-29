# A self-sufficient dev / deploy / maintenance toolkit.
#
#   nix develop            → shell with every CLI this project needs
#   nix run .#toolkit      → list every command
#   nix run .#env-doctor   → which catalogued env vars are set (NAMES only, never values)
#   nix run .#stack-up     → project-local Postgres+pgvector (socket-only) + job runner
#
# ADAPT markers show what must change per project. Everything else is portable.
#
# Two rules encoded here that are easy to "simplify" into a broken state:
#   1. Postgres is invoked through the `withPackages` UNION prefix (`${pg}/bin/...`) and never
#      realpath'd — realpath lands on the plain package and silently loses pgvector.
#   2. The socket URL carries the PORT, because a socket's filename is `<dir>/.s.PGSQL.<port>`.
{
  description = "project toolkit"; # ADAPT

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      project = "app"; # ADAPT: used for state dirs and the default database name

      # Load the project's own `.env` files into the environment WITHOUT overriding anything the
      # caller already exported. Shared verbatim by the CLI apps' prelude and by the dev shell.
      #
      # WHY, given `.envrc` already does this: direnv covers an interactive `cd` into the repo,
      # but `nix run .#deploy-prod` from a script, a CI step, or a shell where direnv is not
      # hooked would otherwise see none of it. Loading here means a command behaves the same
      # either way, and it is idempotent — anything direnv already exported is left untouched.
      #
      # PRECEDENCE, and why the file order looks backwards: each variable is set only if it is
      # currently unset, so the FIRST file to mention a name wins. Reading highest-precedence
      # first therefore yields ambient env > .env.development.local > .env.local > .env, which
      # is Next.js's own order — the same one `.envrc` produces via direnv's opposite
      # last-wins semantics. Values are never echoed; this is secret material.
      dotenvLoader = ''
        _load_dotenv() {
          [ -f "$1" ] || return 0
          while IFS= read -r _line || [ -n "$_line" ]; do
            # The empty pattern is written with DOUBLE quotes on purpose: a pair of single
            # quotes terminates a Nix indented string, so the obvious spelling would end this
            # block mid-function. (Writing that fact out plainly, for the same reason.)
            case "$_line" in "" | '#'*) continue ;; esac
            _line="''${_line#export }"
            _key="''${_line%%=*}"
            # Skip anything that is not a plain NAME= assignment (blank keys, `foo bar`, etc.).
            case "$_key" in "" | *[!A-Za-z0-9_]*) continue ;; esac
            _val="''${_line#*=}"
            # Strip one layer of surrounding quotes, the only quoting dotenv files really use.
            case "$_val" in
              \"*\") _val="''${_val#\"}"; _val="''${_val%\"}" ;;
              \'*\') _val="''${_val#\'}"; _val="''${_val%\'}" ;;
            esac
            # Indirect expansion: only set the name if the caller has not already exported it.
            [ -n "''${!_key:-}" ] || export "$_key=$_val"
          done < "$1"
          unset _line _key _val
        }
        _load_project_dotenv() {
          _load_dotenv "$1/.env.development.local"
          _load_dotenv "$1/.env.local"
          _load_dotenv "$1/.env"
        }
      '';

      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
      lib = nixpkgs.lib;

      # ── Env catalogue: the single source of truth. ────────────────────────────────────────────
      # need   : required | optional | ci | local
      # secret : true → tooling reports PRESENCE ONLY, never the value
      # used   : true when the application source reads it (omit for tooling-only vars)
      # ADAPT: harvest with
      #   grep -rhoE 'process\.env\.[A-Z0-9_]+' src/ | sed 's/process\.env\.//' | sort -u
      envCatalogue = {
        DATABASE_URL = {
          need = "required";
          secret = true;
          used = true;
          note = "Runtime connection string.";
        };
        NODE_ENV = {
          need = "optional";
          secret = false;
          used = true;
        };
        GH_TOKEN = {
          need = "optional";
          secret = true;
          note = "gh CLI; also used by runner-provision.";
        };
        CLOUDFLARE_API_TOKEN = {
          need = "optional";
          secret = true;
          note = "wrangler / DNS. Tooling-consumed, not read by the app.";
        };
        PG_PORT = {
          need = "local";
          secret = false;
          note = "Local cluster port. Default 5433.";
        };
      };

      envNames = lib.attrNames envCatalogue;
      envTsv = lib.concatMapStringsSep "\n" (
        n:
        let
          e = envCatalogue.${n};
        in
        lib.concatStringsSep "\t" [
          n
          (e.need or "optional")
          (if (e.secret or false) then "secret" else "plain")
          (e.note or "")
        ]
      ) envNames;
    in
    {
      formatter = forAll (_: pkgs: pkgs.nixfmt-rfc-style);

      packages = forAll (
        system: pkgs:
        let
          # The UNION prefix. Never realpath a binary out of this — see the header.
          pg = pkgs.postgresql_16.withPackages (p: [ p.pgvector ]);
          node = pkgs.nodejs_22;
          envTsvFile = pkgs.writeText "${project}-env-catalogue.tsv" envTsv;

          # `export`, not plain assignment: commands share this prelude but use only part of it,
          # and an unexported variable would be flagged unused by shellcheck.
          prelude = dotenvLoader + ''
            export PRJ="''${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
            # The project's own .env files, for the case direnv does not cover (a script, CI, a
            # shell with no direnv hook). Never overrides what the caller already exported.
            _load_project_dotenv "$PRJ"
            export STACK="''${PROJECT_STACK_DIR:-$PRJ/.nix-stack}"
            export PGDATA_DIR="$STACK/pg/data"
            export PGPORT_="''${PG_PORT:-5433}"
            export PGUSER_="postgres"
            export PGDB_="''${PG_DB:-${project}_dev}"

            # ~104-byte cap on a unix socket's full name (macOS), and the name embeds the port.
            # A deep checkout blows it, so fall back to a short /tmp path keyed by the project.
            export SOCK="$STACK/pg/sock"
            if [ ''${#SOCK} -gt 60 ]; then
              SOCK="/tmp/pgdev-$(printf '%s' "$PRJ" | cksum | cut -d' ' -f1)"
            fi
          '';

          mk =
            {
              name,
              deps ? [ ],
              text,
            }:
            pkgs.writeShellApplication {
              inherit name;
              runtimeInputs = deps;
              text = prelude + text;
            };
        in
        {
          pg-init = mk {
            name = "pg-init";
            text = ''
              [ -s "$PGDATA_DIR/PG_VERSION" ] && { echo "[pg] already initialised"; exit 0; }
              mkdir -p "$PGDATA_DIR" "$SOCK"
              chmod 700 "$PGDATA_DIR" "$SOCK"
              ${pg}/bin/initdb -D "$PGDATA_DIR" -U "$PGUSER_" \
                --auth=trust --encoding=UTF8 --no-locale --no-sync
              echo "[pg] initialised at $PGDATA_DIR"
            '';
          };

          pg-start = mk {
            name = "pg-start";
            text = ''
              [ -s "$PGDATA_DIR/PG_VERSION" ] || { echo "run pg-init first" >&2; exit 1; }
              if ${pg}/bin/pg_ctl -D "$PGDATA_DIR" status >/dev/null 2>&1; then
                echo "[pg] already running on $SOCK:$PGPORT_"; exit 0
              fi
              mkdir -p "$SOCK"; chmod 700 "$SOCK"
              # listen_addresses is set EMPTY below → no TCP at all, so no port can clash.
              # Three quotes, not two: two would close this Nix indented string. Even a comment
              # mentioning the bare two-quote form ends the string — this file hit that once.
              ${pg}/bin/pg_ctl -D "$PGDATA_DIR" -w -l "$STACK/pg/postgres.log" \
                -o "-p $PGPORT_ -k $SOCK -c listen_addresses=''' -c fsync=off" start
              ${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d postgres -Atqc \
                "SELECT 1 FROM pg_database WHERE datname='$PGDB_'" | grep -q 1 \
                || ${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d postgres -Atqc \
                     "CREATE DATABASE \"$PGDB_\""
              ${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d "$PGDB_" -Atqc \
                "CREATE EXTENSION IF NOT EXISTS vector" >/dev/null
              echo "[pg] up — socket $SOCK, port $PGPORT_, db $PGDB_, pgvector ready"
            '';
          };

          pg-stop = mk {
            name = "pg-stop";
            text = ''
              ${pg}/bin/pg_ctl -D "$PGDATA_DIR" -m fast -w stop 2>/dev/null || true
              echo "[pg] stopped"
            '';
          };

          pg-destroy = mk {
            name = "pg-destroy";
            text = ''
              # Deletes only this project's own cluster directory. It takes no database NAME, so it
              # can never be pointed at a neighbouring database on a shared server.
              ${pg}/bin/pg_ctl -D "$PGDATA_DIR" -m immediate -w stop 2>/dev/null || true
              rm -rf "$STACK/pg"
              echo "[pg] destroyed $STACK/pg"
            '';
          };

          pg-url = mk {
            name = "pg-url";
            deps = [ pkgs.python3 ];
            text = ''
              # Percent-encode the socket dir (it contains /), and CARRY THE PORT: a socket's
              # filename is <dir>/.s.PGSQL.<port>, so omitting it sends clients to the default.
              enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$SOCK")
              echo "postgresql://$PGUSER_@localhost:$PGPORT_/$PGDB_?host=$enc"
            '';
          };

          pg-status = mk {
            name = "pg-status";
            text = ''
              if ${pg}/bin/pg_ctl -D "$PGDATA_DIR" status >/dev/null 2>&1; then
                echo "[pg] running — $SOCK:$PGPORT_"
                echo "[pg] vector: $(${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d "$PGDB_" \
                  -Atqc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null \
                  || echo 'NOT INSTALLED')"
              else
                echo "[pg] stopped"
              fi
            '';
          };

          pg-psql = mk {
            name = "pg-psql";
            text = ''exec ${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d "$PGDB_" "$@"'';
          };

          env-doctor = mk {
            name = "env-doctor";
            text = ''
              # Reports PRESENCE ONLY. Never prints a value. Note this sees the ambient
              # environment — it does not load .env files.
              miss=0; total=0
              printf '%-34s %-9s %-8s %s\n' VARIABLE NEED KIND STATUS
              while IFS=$'\t' read -r n need kind _note; do
                [ -z "$n" ] && continue
                total=$((total+1))
                if [ -n "''${!n:-}" ]; then st="set"; else
                  st="MISSING"; [ "$need" = required ] && miss=$((miss+1))
                fi
                printf '%-34s %-9s %-8s %s\n' "$n" "$need" "$kind" "$st"
              done < ${envTsvFile}
              echo
              if [ "$miss" -gt 0 ]; then echo "$miss required variable(s) missing."; exit 1; fi
              echo "all $total variables present."
            '';
          };

          env-template = mk {
            name = "env-template";
            text = ''
              out="''${1:-.env.example}"
              [ -e "$out" ] && { echo "refusing to overwrite $out" >&2; exit 1; }
              {
                echo "# Generated by 'nix run .#env-template'. Values are intentionally BLANK."
                echo "# Never commit a real secret."
                echo
                while IFS=$'\t' read -r n need kind note; do
                  [ -z "$n" ] && continue
                  [ -n "$note" ] && echo "# $note"
                  echo "# need=$need kind=$kind"
                  echo "$n="
                  echo
                done < ${envTsvFile}
              } > "$out"
              echo "wrote $out"
            '';
          };

          stack-up = mk {
            name = "stack-up";
            deps = [ node ];
            text = ''
              ${self.packages.${system}.pg-init}/bin/pg-init
              ${self.packages.${system}.pg-start}/bin/pg-start
              # ADAPT: start the project's own background services here.
              echo "[stack] up — DATABASE_URL=$(${self.packages.${system}.pg-url}/bin/pg-url)"
            '';
          };

          stack-down = mk {
            name = "stack-down";
            text = ''
              ${self.packages.${system}.pg-stop}/bin/pg-stop
              echo "[stack] down"
            '';
          };

          toolkit = mk {
            name = "toolkit";
            text = ''
              echo "commands: ${lib.concatStringsSep " " (lib.attrNames self.packages.${system})}"
            '';
          };
        }
      );

      apps = forAll (
        system: _:
        lib.mapAttrs (name: drv: {
          type = "app";
          program = "${drv}/bin/${name}";
        }) self.packages.${system}
      );

      devShells = forAll (
        system: pkgs:
        let
          pg = pkgs.postgresql_16.withPackages (p: [ p.pgvector ]);
        in
        {
          default = pkgs.mkShell {
            # ADAPT: add the CLIs this project actually shells out to. Check availability first
            # with `nix search nixpkgs <name>`; some (e.g. vercel, inngest-cli) are not packaged
            # and should stay on `npx --yes` with the version pinned in one place above.
            packages = [
              pkgs.nodejs_22
              pg
              pkgs.gh
              pkgs.git
              pkgs.jq
              pkgs.yq-go
              pkgs.curl
              pkgs.openssl
            ];
            shellHook = dotenvLoader + ''
              # Same loader the commands use: a bare `nix develop` with no direnv should still see
              # the project's env. A no-op when direnv has already exported it.
              _load_project_dotenv "$PWD"
              echo "${project} dev shell — $(node --version)"
              echo "env: nix run .#env-doctor (${toString (builtins.length envNames)} catalogued vars)"
              echo "stack: nix run .#stack-up"
            '';
          };
        }
      );

      checks = forAll (system: _: self.packages.${system});
    };
}
