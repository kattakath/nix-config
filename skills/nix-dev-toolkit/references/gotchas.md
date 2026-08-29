# Traps, and the symptom each one produces

Every entry here was paid for once. They are grouped by what breaks, and each names the *symptom*
first so a failure in the wild can be matched back to its cause without re-deriving it.

## Nix packaging

### Never realpath a `withPackages` binary

**Symptom:** `ERROR: extension "vector" is not available` / `Could not open extension control file
".../share/postgresql/extension/vector.control"`, appearing many migrations into a run that started
fine — so it reads like a migration bug rather than a provisioning one. Under Prisma it surfaces as
`P3018`.

**Cause:** `postgresql_16.withPackages (p: [ p.pgvector ])` produces an lndir tree where
`share/postgresql` is the **union** (`postgres.bki` from Postgres plus `vector.control` from
pgvector) but `bin/initdb` is a **symlink back to the plain postgresql store path**. Postgres locates
`share/` and `lib/` relative to the prefix it was *invoked* through. Resolve the binary to its real
path and the prefix becomes the plain package, which has no pgvector.

**Rule:** always invoke through `${pg}/bin/<tool>` — the union prefix — and never `realpath`,
`readlink -f`, or `command -v` it into a variable.

### A user profile cannot expose `share/postgresql`

**Symptom:** `initdb: error: file ".../share/postgresql/postgres.bki" does not exist` … `This might
mean you have a corrupted installation`, when the binary is plainly on `PATH`.

**Cause:** reaching Postgres through a Nix *profile* (`/etc/profiles/per-user/<u>/bin`,
`~/.nix-profile/bin`). nix-darwin/home-manager build those profiles with a restricted `pathsToLink`
(`bin`, `share/man`, `share/info`), so `share/postgresql` is **never linked there** — no matter what
is added to `home.packages`. `initdb` computes a path that does not exist.

**Rule:** when Postgres must be found on `PATH` rather than referenced as a store path, pick the
first `PATH` entry whose prefix carries **both** `share/postgresql/postgres.bki` and
`share/postgresql/extension/vector.control`, and use that prefix as-is. If none qualifies, realise
one directly:

```bash
nix build --no-link --print-out-paths --impure --expr \
  'let pkgs = import (builtins.getFlake "nixpkgs") {}; in pkgs.postgresql_16.withPackages (p: [ p.pgvector ])'
```

Inside a flake this problem does not arise — reference `${pg}` directly.

### Two quoting hazards inside Nix strings

**Symptom:** an unhelpful Nix parse error, or a shell command that silently does the wrong thing.

- `''` **terminates a Nix indented string.** Writing `-c listen_addresses=''` inside `text = '' ... ''`
  ends the string early. Escape it as `listen_addresses='''` (Nix's `''` escape) or use `""`.
- **Backticks perform command substitution** in the generated shell script. Markdown-style backticks
  inside a comment in a shell body will execute. Use plain quotes in shell comments.

`writeShellApplication` runs `shellcheck` at build time and catches most of the second class.

## Postgres

### The connection URL must carry the port, even over a unix socket

**Symptom:** `Can't reach database server at /path/to/socketdir:5432` (Prisma `P1001`) when the
server is demonstrably running on a different port.

**Cause:** a unix socket's *filename* embeds the port — `<dir>/.s.PGSQL.<port>`. Omitting the port
makes libpq look for `.s.PGSQL.5432`.

**Rule:** build socket URLs as
`postgresql://<user>@localhost:<port>/<db>?host=<url-encoded socket dir>`. The `localhost` authority
is inert; `host=` selects the socket directory; the port names the file. Percent-encode the
directory — it contains `/`.

### The socket path has a ~104-byte limit on macOS

**Symptom:** connect failures, or `pg_ctl` refusing to start, on a deeply nested checkout while the
same flake works elsewhere.

**Rule:** compute the socket dir, and if it exceeds ~60 bytes fall back to a short `/tmp` path keyed
by a hash of the project path so two projects still get different sockets:

```bash
SOCK="$STACK/pg/sock"
if [ ${#SOCK} -gt 60 ]; then
  SOCK="/tmp/pgdev-$(printf '%s' "$PRJ" | cksum | cut -d' ' -f1)"
fi
```

### Guard every drop by name

**Symptom:** a real database disappears.

**Cause:** a teardown command running from a `finally` with whatever a stale environment variable
happened to hold, on a machine that also hosts real databases.

**Rule:** refuse any name outside the expected pattern before dropping, and prefer a whole
throwaway *cluster* over a database on a shared server — a separate cluster cannot name, let alone
drop, a neighbour.

```bash
case "$DB" in
  devstack-*) ;;
  *) echo "refusing to drop '$DB' — only devstack-* databases may be dropped" >&2; exit 1 ;;
esac
```

### `CREATE DATABASE` cannot run in a transaction

Issue it as a bare statement. Quote the identifier (`"name-with-dashes"`) so a dashed name is legal;
dashes are often preferable because tooling allowlists tend to match a `prefix-` marker.

## Prisma

### Do not point `PRISMA_*_ENGINE_BINARY` at nixpkgs blindly

**Symptom:** engine version mismatch errors, or a client that cannot start at all.

**Cause:** nixpkgs' `prisma-engines` tracks its own release train and frequently does not match the
`prisma` version in `package.json`. The same applies to `PLAYWRIGHT_BROWSERS_PATH` versus
`@playwright/test`.

**Rule:** compare versions first (`nix eval nixpkgs#prisma-engines.version` against
`package.json`). If they differ, leave the variables unset and say so in a flake comment — an
explicit omission with a reason is worth more than a broken convenience.

### Regenerate the client after a schema change, and restart long-running dev servers

**Symptom:** `Cannot read properties of undefined (reading 'findMany')` on a model that exists in
`schema.prisma`, only in a server that has been running a while.

**Cause:** a long-lived dev server holds the **previously generated** client in memory. New models
are absent from it.

**Rule:** after `prisma generate`, restart dev servers. When diagnosing, check the delegate in a
fresh process (`node -e 'const {PrismaClient}=require("@prisma/client"); console.log(typeof new
PrismaClient().yourModel)'`) before concluding the code is wrong.

## GitHub self-hosted runners

### The runner's PATH is not the login shell's PATH

**Symptom:** `spawnSync <tool> ENOENT` in a job, for a tool that works in a terminal on the same
machine.

**Cause:** a daemon-managed runner has an explicitly declared, minimal PATH. A runner started from a
login session inherits that session's environment instead. The two differ, so a job's success can
depend on **which runner it landed on** — a run may show one DB job green and another red on the
same commit.

**Rule:** enumerate the runners that match the job's labels (`gh api repos/{owner}/{repo}/actions/runners`
and the org equivalent) before assuming one environment. Prefer making the job provide its own
toolchain — via `nix develop` — over provisioning each runner identically.

### Registration tokens are short-lived and must not be persisted

Mint at use, pass directly, unset immediately:

```bash
TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
./config.sh --url "https://github.com/$REPO" --token "$TOKEN" --unattended
unset TOKEN
```

Never echo it, never write it to a file, never put it in a log line.
