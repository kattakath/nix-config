---
name: nix-dev-toolkit
description: This skill should be used when the user asks to "create a flake.nix for this project", "add a dev shell", "set up a local Postgres with pgvector", "run a local stack", "provision a self-hosted GitHub runner", "make a self-sufficient toolkit", "add nix apps for deploy and maintenance", "audit which env vars are set", or otherwise wants a repo made self-contained with Nix for development, deployment and maintenance. Provides a working flake template, an env-catalogue pattern, and the Nix/Postgres/Prisma traps that cost real debugging time.
version: 0.1.0
---

# Nix dev / deploy / maintenance toolkit

Turn any repo into a self-sufficient Nix project: one `flake.nix` providing a dev shell with every
CLI the project needs, a catalogue of every environment variable it reads, a project-local service
stack (Postgres + pgvector, a job runner, a self-hosted CI runner), and named `nix run .#<app>`
commands for the operations people actually perform.

Four deliverables, in the order they pay off:

1. **Dev shell** — every CLI pinned, so `nix develop` is the whole onboarding step.
2. **Env catalogue** — one attrset naming every variable, from which tooling is *generated*.
3. **Local stack** — services that cannot collide with anything else on the machine.
4. **Lifecycle apps** — `nix run .#<verb>` for provisioning, migrating, deploying, tearing down.

## Before writing anything

Harvest the truth from the repo instead of inventing it.

```bash
# Every env var the source actually reads — the seed for the catalogue.
grep -rhoE 'process\.env\.[A-Z0-9_]+' src/ | sed 's/process\.env\.//' | sort -u
grep -rhoE '\$\{\{ *secrets\.[A-Z0-9_]+' .github/workflows/ | grep -oE '[A-Z0-9_]+$' | sort -u

# Every CLI the project already shells out to.
grep -rhoE 'npx --(yes|no-install) [a-z@/-]+' package.json .github/ scripts/ | sort -u
```

Check each CLI is actually packaged before promising it: `nix search nixpkgs <name>`. Some
common ones are **not** in nixpkgs (at time of writing: `vercel`, `inngest-cli`). Leave those on
`npx --yes`, but pin the version string in **one** place in the flake rather than scattering it
across workflow steps. State that limitation in the flake's header comment.

## Structure

Use `writeShellApplication` for every command — it runs `shellcheck` at build time, so a broken
command fails `nix build`, not the user's afternoon. Share one `prelude` string across commands
that resolve project paths.

```nix
mk = { name, deps ? [ ], text }:
  pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = deps;
    text = prelude + text;
  };
```

Expose commands as `apps.<system>.<name>` and keep the derivations in `packages` so
`nix flake check` builds (and shellchecks) all of them. Add a `checks` output so `nix flake check`
is a real gate.

Guidance on writing the shell bodies is in **`references/local-stack.md`**; the traps that make
these programs fail in non-obvious ways are in **`references/gotchas.md`**.

## The env catalogue

Declare one attrset naming every variable, each tagged with how badly it is needed and whether it
is a secret. Generate the tooling from it so documentation cannot drift from reality.

```nix
envCatalogue = {
  DATABASE_URL = { need = "required"; secret = true;  used = true; note = "..."; };
  VERCEL_TOKEN = { need = "required"; secret = true;  note = "CLI reads env; never pass --token."; };
  PG_SOCKET_DIR = { need = "local"; secret = false; };
};
# need   : required | optional | ci | local
# secret : true → tools report PRESENCE ONLY, never the value
# used   : true if the application source reads it (vs. tooling-only, e.g. CLOUDFLARE_API_TOKEN)
```

Generate two commands from it:

- **`env-doctor`** — prints a table of name / need / kind / `set`|`MISSING`, exits non-zero when a
  `required` one is missing. It must test presence with `[ -n "${!n:-}" ]` and print **only the
  name**. Never echo, log, or interpolate a secret's value.
- **`env-template`** — writes a `.env.example` with blank values and the notes as comments, and
  refuses to overwrite an existing file.

Full rendering pattern, including the TSV trick that avoids quoting problems:
**`references/env-catalogue.md`**.

## The local stack

Make services **project-local and socket-only** so they can never collide with, or damage, anything
already on the machine.

- Put state under `$PRJ/.nix-stack/` and add it to `.gitignore`.
- Run Postgres with `-c listen_addresses=''` — no TCP, so no port can clash.
- Give every destructive command a name guard (refuse to drop a database not matching the expected
  prefix). Other real databases live on the same machine.
- Provide `stack-up` / `stack-down` / `stack-status` that compose the individual services.

For a self-hosted GitHub runner, wrap nixpkgs' `github-runner`, mint the registration token with
`gh api -X POST repos/$REPO/actions/runners/registration-token --jq .token`, pass it straight to
`config.sh --token`, then `unset` it. Never write it to a file or echo it.

Complete command bodies — cluster init, start/stop, URL construction, runner provisioning — are in
**`references/local-stack.md`**.

## Non-obvious traps

These cost real debugging time. Read **`references/gotchas.md`** before writing Postgres or
Prisma/Playwright integration; the three that bite hardest:

- **Never realpath a `withPackages` binary.** `postgresql_16.withPackages (p: [ p.pgvector ])`
  builds an lndir tree whose `share/postgresql` is the union but whose `bin/*` symlink *back* to
  the plain package. Resolving the real path silently loses pgvector, surfacing much later as
  `extension "vector" is not available`.
- **A socket connection URL must carry the port.** The socket filename is
  `<dir>/.s.PGSQL.<port>`, so omitting the port sends clients to the default and fails to connect.
- **A unix socket path has a ~104-byte limit on macOS.** A deep checkout blows it. Fall back to a
  short `/tmp` path keyed by a hash of the project path rather than failing obscurely.

Do **not** point `PRISMA_*_ENGINE_BINARY` or `PLAYWRIGHT_BROWSERS_PATH` at nixpkgs store paths
without checking versions against `package.json` first — a mismatch breaks both, and it is usually
the wrong trade. Say so in a comment rather than leaving it to be rediscovered.

## Workflow

1. Harvest env vars and CLIs from the source (commands above).
2. Copy **`assets/flake-template.nix`** to the repo root as `flake.nix`.
3. Replace the `project` binding, fill `envCatalogue` from the harvest, add the project's CLIs to
   `devTools`, and delete any stack service the project does not use.
4. Add the state dir to `.gitignore`.
5. Validate: `nix flake check` (builds and shellchecks every command), then
   `nix develop --command <cli> --version` for each CLI the project relies on.
6. Smoke-test the stack end to end: `nix run .#stack-up`, apply the project's real migrations,
   confirm the extension loaded, `nix run .#stack-down`, and verify no other database was touched.
7. Commit `flake.nix`, `flake.lock`, and the `.gitignore` change together.

Prefer adding a command to the flake over documenting a manual procedure in a README — a
`writeShellApplication` is checked at build time; a README is not.

## Additional resources

### Reference files

- **`references/local-stack.md`** — Postgres+pgvector cluster lifecycle, socket URL construction,
  Inngest/job-runner wrapping, self-hosted GitHub runner provisioning, name guards.
- **`references/env-catalogue.md`** — rendering `env-doctor` and `env-template` from the catalogue,
  the TSV pattern, and the secret-handling rules.
- **`references/gotchas.md`** — Nix/Postgres/Prisma/Playwright traps with the symptom each one
  produces, so a failure can be matched back to its cause.

### Assets

- **`assets/flake-template.nix`** — a working, genericised starting point with the dev shell, env
  catalogue, Postgres+pgvector stack and lifecycle apps already wired. Copy and adapt; the
  `# ADAPT:` markers show what must change per project.
