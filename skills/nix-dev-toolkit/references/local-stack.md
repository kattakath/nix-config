# Local stack: Postgres + pgvector, job runner, self-hosted CI runner

The stack must be **project-local and socket-only**, so that starting it can never collide with,
or damage, anything already on the machine. State lives under `$PRJ/.nix-stack/` (gitignored).

## The shared prelude

Every command begins from the same resolved paths. Export rather than assign: `writeShellApplication`
runs `shellcheck`, and a plain variable used by only some commands is flagged unused.

```nix
prelude = ''
  export PRJ="''${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  export STACK="''${PROJECT_STACK_DIR:-$PRJ/.nix-stack}"
  export PGDATA_DIR="$STACK/pg/data"
  export PGPORT_="''${PROJECT_PG_PORT:-5433}"
  export PGUSER_="''${PROJECT_PG_USER:-postgres}"
  export PGDB_="''${PROJECT_PG_DB:-app_dev}"

  # A unix socket's FULL filename must fit ~104 bytes on macOS and embeds the port
  # (<dir>/.s.PGSQL.<port>). A deep checkout blows that, so fall back to a short /tmp path
  # keyed by a hash of the project path rather than failing obscurely at connect time.
  export SOCK="$STACK/pg/sock"
  if [ ''${#SOCK} -gt 60 ]; then
    SOCK="/tmp/pgdev-$(printf '%s' "$PRJ" | cksum | cut -d' ' -f1)"
  fi
'';
```

Trailing underscores (`PGPORT_`) avoid colliding with libpq's own `PGPORT`, which would silently
retarget every `psql` invocation in the shell.

## Postgres

Bind the union package **once** and route every call through it. See `gotchas.md` for why this must
never be realpath'd.

```nix
pg = pkgs.postgresql_16.withPackages (p: [ p.pgvector ]);
```

### `pg-init`

```bash
[ -s "$PGDATA_DIR/PG_VERSION" ] && { echo "[pg] already initialised"; exit 0; }
mkdir -p "$PGDATA_DIR" "$SOCK"
chmod 700 "$PGDATA_DIR" "$SOCK"
${pg}/bin/initdb -D "$PGDATA_DIR" -U "$PGUSER_" \
  --auth=trust --encoding=UTF8 --no-locale --no-sync
```

`--auth=trust` is safe **because the only listener is a socket in a 0700 directory owned by the
invoking user** — there is no TCP door to guard. `--no-sync` is safe for a disposable cluster and
saves real wall-clock on every init.

### `pg-start`

```bash
if ${pg}/bin/pg_ctl -D "$PGDATA_DIR" status >/dev/null 2>&1; then
  echo "[pg] already running on $SOCK:$PGPORT_"; exit 0
fi
mkdir -p "$SOCK"; chmod 700 "$SOCK"
${pg}/bin/pg_ctl -D "$PGDATA_DIR" -w -l "$STACK/pg/postgres.log" \
  -o "-p $PGPORT_ -k $SOCK -c listen_addresses=''' -c fsync=off" start
```

- `listen_addresses=''` → **no TCP at all**: no port can clash, nothing off-box can connect.
  Note the `'''` — `''` would terminate the Nix indented string (see `gotchas.md`).
- `-w` waits until the server actually accepts connections, so the next command cannot race it.

Then create the database and extension idempotently:

```bash
${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d postgres -Atqc \
  "SELECT 1 FROM pg_database WHERE datname='$PGDB_'" | grep -q 1 \
  || ${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d postgres -Atqc \
       "CREATE DATABASE \"$PGDB_\""
${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d "$PGDB_" -Atqc \
  "CREATE EXTENSION IF NOT EXISTS vector"
```

`CREATE DATABASE` cannot run inside a transaction — issue it bare. Quote the identifier so a dashed
name is legal.

### `pg-url`

The URL other tools consume. Percent-encode the socket directory (it contains `/`) and **include
the port** — the socket filename embeds it:

```bash
enc=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$SOCK")
echo "postgresql://$PGUSER_@localhost:$PGPORT_/$PGDB_?host=$enc"
```

### `pg-stop` / `pg-destroy`

```bash
# stop
${pg}/bin/pg_ctl -D "$PGDATA_DIR" -m fast -w stop || true

# destroy — immediate, because the directory is about to be deleted and a hung
# client connection must never be able to stall teardown.
${pg}/bin/pg_ctl -D "$PGDATA_DIR" -m immediate -w stop 2>/dev/null || true
rm -rf "$STACK/pg"
```

`pg-destroy` deletes only `$STACK/pg` — a directory this flake created, inside the project. It never
takes a database *name*, so it cannot be pointed at a neighbour. That is the strongest form of the
name-guard rule in `gotchas.md`: prefer destroying a whole project-local cluster over dropping a
database on a shared server.

## Job runner (Inngest and similar)

For a CLI nixpkgs does not package, pin the version in one place and invoke via `npx`:

```nix
inngestPkg = "inngest-cli@latest";  # ADAPT: pin a version once a release is chosen
```

```bash
# inngest-start
exec ${pkgs.nodejs_22}/bin/npx --yes ${inngestPkg} dev \
  -u "http://localhost:${PORT}/api/inngest" --no-discovery
```

`--no-discovery` matters on a machine that may host several checkouts: without it the dev server
adopts whatever app it finds on a common port, and runs execute against the wrong build — a failure
that looks like the code is broken rather than the wiring.

## `stack-up` / `stack-down` / `stack-status`

Compose, do not duplicate. `stack-up` calls `pg-start` then starts the job runner in the background
with its log under `$STACK`; `stack-down` reverses it; `stack-status` prints one line per service
plus the extension version, which is the fastest way to catch a plain-Postgres regression:

```bash
echo "[pg] vector: $(${pg}/bin/psql -h "$SOCK" -p "$PGPORT_" -U "$PGUSER_" -d "$PGDB_" \
  -Atqc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null || echo 'NOT INSTALLED')"
```

## Self-hosted GitHub runner

Wrap nixpkgs' `github-runner`. Keep the runner's state under `$STACK/runner`.

```bash
# runner-provision
REPO="''${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
NAME="''${RUNNER_NAME:-$(hostname -s)-$(basename "$PRJ")}"
LABELS="''${RUNNER_LABELS:-self-hosted,$(uname -s),$(uname -m)}"
DIR="$STACK/runner"; mkdir -p "$DIR"; cd "$DIR"
cp -r ${pkgs.github-runner}/* . 2>/dev/null || true

TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
./config.sh --url "https://github.com/$REPO" --token "$TOKEN" \
  --name "$NAME" --labels "$LABELS" --work "$DIR/_work" --unattended --replace
unset TOKEN
echo "[runner] configured $NAME ($LABELS)"
```

The token is minted at use, passed straight to `config.sh`, then unset — never written to a file,
never echoed. `runner-remove` mints a *remove* token the same way.

**Label collisions are the trap.** Several runners may match the same `runs-on` labels while having
different environments, so a job's outcome depends on where it landed. Before assuming one
environment, enumerate them:

```bash
gh api "repos/$REPO/actions/runners" --jq '.runners[] | "\(.name) \(.status) [\(.labels|map(.name)|join(","))]"'
gh api "orgs/$ORG/actions/runners"   --jq '.runners[] | "\(.name) \(.status) [\(.labels|map(.name)|join(","))]"'
```

The durable fix is to have the workflow provide its own toolchain (`nix develop --command ...`)
rather than provisioning every runner identically.

## Validation

A stack is only proven when it has done the real work:

1. `nix flake check` — builds and shellchecks every command.
2. `nix run .#stack-up`, then `nix run .#stack-status` — confirm the extension version prints.
3. Apply the project's **real** migrations against `pg-url`, including any `CREATE EXTENSION`.
4. `nix run .#stack-down` / `pg-destroy`, then confirm no other cluster on the machine changed.
