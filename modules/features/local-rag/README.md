# local-rag

A local-first RAG (retrieval-augmented generation) stack for macOS, declared as
home-manager `launchd` user agents: a loopback-only **Postgres + pgvector +
pgsql-http**, a loopback-only **Ollama** (home-manager's own `services.ollama`),
and a one-shot agent that pulls the embed model. Bootstrap SQL wires them together
with an in-DB `public.embed(text)` `SECURITY DEFINER` function that calls
Ollama over loopback HTTP, plus a `public.docs` table (content + jsonb
metadata + a vector column) and an HNSW cosine index — so ingest and retrieval
are both **plain SQL**:

```sql
INSERT INTO docs (content, embedding) VALUES ($1, embed($1));
SELECT content, metadata FROM docs ORDER BY embedding <=> embed($2) LIMIT 8;
```

No API key, no vector-DB client library, nothing leaves the machine.

> **Provenance.** This was `github.com/kattakath/nix-local-rag`, a standalone MIT
> flake, until ADR-002 ([`docs/monoflake-capsule-adr.md`](../../../docs/monoflake-capsule-adr.md))
> collapsed the seven satellites into this repo as *capsules* — this was the last
> of them. The code arrived by plain copy; the git history stays in the archived
> origin repo. MIT © Ismail Kattakath.

## Prerequisites

- **macOS on Apple Silicon** (`aarch64-darwin`) — the modules declare
  `launchd.agents`, macOS's user-agent mechanism.
- **Nix** with flakes enabled (`experimental-features = nix-command flakes`).
- **[home-manager](https://github.com/nix-community/home-manager)**.
- Disk space for the Ollama embed model (a few hundred MB for
  `nomic-embed-text`, more for larger models) and whatever corpus you ingest.

## How it is wired here

There is no input to add and no flake to fetch. The capsule's
[`flake-module.nix`](./flake-module.nix) registers both modules as one
`capsuleModules.homeManager.local-rag`; `modules/parts/compose.nix` threads that
through `extraSpecialArgs` as `localRagModule`, and `modules/shared/home.nix`
imports it **unconditionally** and enables it on `macos` only:

```nix
services.ollamaLocal.enable = isMacosHost;
services.pgvectorLocal.enable = isMacosHost;
```

Both modules gate their own `config` on `enable && isDarwin`, so the import is a
clean no-op on `nixpi`/`nixvm` — asserted by `checks.<system>.local-rag-inert`,
which also proves an unset switch adds nothing to `home.packages`. There is
deliberately **no** third `programs.localRag.enable` wrapping them (ADR-002 §4:
a consumer that wants only the embedding half must keep being able to say so).

To use the two halves separately, import `./ollama-local.nix` or
`./pgvector-local.nix` — the latter imports the former, so it is standalone.

## Options

Both default to loopback-only, no auth needed:

```nix
{
  services.ollamaLocal = {
    enable = true;
    # embedModel = "nomic-embed-text";  # default, 768-dim
    # embedDim = 768;           # must match embedModel's output dimension
  };

  # The Ollama SERVER is home-manager's own `services.ollama`, which
  # `ollamaLocal` enables for you. Its coordinates live there, not here:
  # services.ollama = {
  #   host = "127.0.0.1";       # default
  #   port = 11434;             # default
  # };

  services.pgvectorLocal = {
    enable = true;
    # port = 5433;              # default; off 5432 to dodge a Homebrew postgres
    # role = "mcp";             # default; owns `db`, no rights elsewhere
    # db = "ragdb";             # default
    # dataDir = "${config.home.homeDirectory}/.local/share/postgres-pgvector"; # default
  };
}
```

`pgvectorLocal` single-sources Ollama's coordinates into its bootstrap SQL (the
embed function's URL and the `vector(...)` column width), so it's enough to
change them in one place: `services.ollama`'s `host`/`port` for the URL,
`ollamaLocal`'s `embedModel`/`embedDim` for the model and column width. The
`pgvectorLocal` module imports `ollamaLocal` itself, so it evaluates standalone
even if you only reference the postgres module directly — but you need
`ollamaLocal.enable = true` too for `embed()` to actually have something to
call at runtime.

## Usage

Once the agents are running (`launchctl list | grep -E 'ollama|postgres-pgvector'`),
connect with any Postgres client — `psql`, a script, or your own MCP
`postgres` server — using `config.services.pgvectorLocal.databaseUri`
(read-only, computed from `role`/`port`/`db`; no secret in it, trust auth on
127.0.0.1):

```sh
psql "$(nix eval --raw .#homeConfigurations.\"you\".config.services.pgvectorLocal.databaseUri)"
```

or just hardcode the default shape: `postgresql://mcp@127.0.0.1:5433/ragdb`.

**This flake does not wire the URI into an MCP server for you** — that
decoupling is deliberate (see below). Point your own tool at it.

```sql
-- ingest
INSERT INTO docs (content, metadata, embedding)
VALUES ($1, $2::jsonb, embed($1));

-- retrieve
SELECT content, metadata, 1 - (embedding <=> embed($1)) AS similarity
FROM docs
ORDER BY embedding <=> embed($1)
LIMIT 8;
```

## Security model

- **Loopback-only binds.** Postgres is hard-bound to `127.0.0.1` — there is no
  `host` option to widen it. Ollama binds its configured `host`, default
  `127.0.0.1`; widening that one is on you.
- **Role/db lockdown.** Postgres's superuser (the macOS login user, created by
  `initdb`) is reachable only over the local Unix socket via `peer` auth. Over
  TCP, only the dedicated `role` may connect, only to `db`, via `trust` (no
  password needed because nothing untrusted can reach loopback Postgres
  without already being a process on your Mac). `role` owns `db` and has no
  rights anywhere else — a compromised consumer's blast radius is exactly that
  one database.
- **`SECURITY DEFINER` embed().** The `http` extension (which can make
  arbitrary outbound HTTP calls) lives in a private `ext` schema that `role`
  has **no** access to. `role` only sees `public.embed(text)`, a fixed-URL
  wrapper — so SQL-injectable or LLM-generated queries running as `role`
  cannot be tricked into arbitrary HTTP via `ext.http_post` directly.
- **No secrets anywhere.** Nothing here needs a password, API key, or token —
  that's what makes emitting `databaseUri` into the Nix store safe. If you
  widen `host` past loopback, you've left this model; add your own auth.

## Used in production

This backs the `postgres` MCP server on `macos`. `modules/shared/mcp.nix` hands
that server `services.pgvectorLocal.databaseUri` as `env.DATABASE_URI` — one
string, and the only path the career RAG (`career_docs` in `ragdb`) has to
Claude Code. `checks/module-evaluations.nix` pins that URI as a literal so a
port/role/db rename fails a check rather than quietly returning zero rows.

The [`rag` skill](https://github.com/kattakath/claude-skills/tree/main/skills/rag)
is how an AI coding agent
is taught to use the resulting `embed()`/`docs` interface.

It travelled out and back: extracted from this repo on 2026-08 (the last
pre-extraction, MCP-coupled versions were `modules/shared/postgres-pgvector.nix`
and `modules/shared/ollama.nix`, at commit `739f8c2`), and absorbed again by
ADR-002 wave 6. It was the only satellite with a second consumer —
`ircc-whatsapp-bot` pinned it too, which is why that unpin (ircc grew a
`botOnly` output) was a wave-0 prerequisite rather than part of the absorption
diff.

## License

MIT © Ismail Kattakath
